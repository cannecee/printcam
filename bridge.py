#!/usr/bin/env python3
"""
PrintCam bridge — Bambu Lab Cloud MQTT -> Cloudflare Worker.

Connects to the printer's status stream via Bambu's CLOUD MQTT broker
(us.mqtt.bambulab.com:8883), not the printer's local LAN broker — this Mac
and the printer are never on the same network, so local MQTT isn't reachable.

Auth: a long-lived Bambu Cloud accessToken (~1 year), obtained ONCE via the
email-verification-code login flow (never the account password — see
README §Telemetri for how that token was obtained). This script only ever
reads that already-issued token from bridge_config.json; it does not log in
itself and never touches the account password.

Fields captured are exactly what was confirmed present in a real payload
from this printer (X2D) during setup — see README for the verification
notes. There is no live "grams used" field from Bambu; grams_used_estimate
is a best-effort derived figure (tray_weight × AMS spool %-drop since the
current print started) that only produces a number if the user has actually
set spool weights in AMS. It stays null otherwise, which is expected for
this printer right now.

Run via setup-bridge.sh (installs a LaunchAgent so this survives reboots/
crashes), or directly with `python3 bridge.py` for one-off testing.
"""

import json
import logging
import os
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt
import requests

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("PRINTCAM_BRIDGE_CONFIG", SCRIPT_DIR / "bridge_config.json"))

MQTT_HOST = "us.mqtt.bambulab.com"
MQTT_PORT = 8883
POST_INTERVAL_S = 5  # how often to push the latest known state to the Worker

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [bridge] %(levelname)s %(message)s",
)
log = logging.getLogger("printcam-bridge")


def load_config():
    if not CONFIG_PATH.exists():
        log.error(
            "config not found at %s — copy bridge_config.example.json to "
            "bridge_config.json and fill in your values (see README §Telemetri)",
            CONFIG_PATH,
        )
        sys.exit(1)
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    required = ["uid", "serial", "access_token", "worker_url", "telemetry_secret"]
    missing = [k for k in required if not cfg.get(k)]
    if missing:
        log.error("bridge_config.json is missing required fields: %s", missing)
        sys.exit(1)
    return cfg


class GramEstimator:
    """Best-effort filament-used estimate, per print run.

    Snapshots each AMS tray's fill % the moment a print starts (state
    transitions into RUNNING), then reports weight_assigned × %-drop since
    that snapshot, summed across trays that have both a valid % reading
    (0-100, not the "-1 unknown" sentinel Bambu uses) and a non-zero
    assigned spool weight. Silently produces nothing (None) if neither
    condition holds — that's expected until spool weights are set in AMS.
    """

    def __init__(self):
        self._baseline = {}  # tray_id -> (remain_at_start, tray_weight)
        self._was_running = False

    def update(self, state, trays):
        is_running = state == "RUNNING"
        if is_running and not self._was_running:
            self._baseline = {
                t["id"]: (t["remain"], t["tray_weight"])
                for t in trays
                if _valid_pct(t["remain"]) and t["tray_weight"] > 0
            }
        self._was_running = is_running

        if not self._baseline:
            return None

        total = 0.0
        any_valid = False
        for t in trays:
            baseline = self._baseline.get(t["id"])
            if baseline is None or not _valid_pct(t["remain"]):
                continue
            start_remain, weight = baseline
            used_pct = max(0, start_remain - t["remain"])
            total += weight * used_pct / 100.0
            any_valid = True

        return round(total, 1) if any_valid else None


def _valid_pct(v):
    return isinstance(v, (int, float)) and 0 <= v <= 100


def deep_merge(base, update):
    """Merge `update` into `base` in place, recursing into nested dicts.

    Needed because Bambu's cloud MQTT only sends a FULL state on the first
    report after a pushall request — every message after that is a DELTA
    containing only the fields that changed (confirmed empirically: a
    message can be as small as a temperature update with nothing else).
    Without merging, each delta would wipe out every field it doesn't
    happen to mention.
    """
    for k, v in update.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def extract_trays(merged_print):
    """Flatten every AMS tray in the merged state into a simple list of dicts."""
    trays = []
    ams = merged_print.get("ams") or {}
    for unit in ams.get("ams", []):
        for tray in unit.get("tray", []):
            try:
                trays.append(
                    {
                        "id": f"{unit.get('id')}:{tray.get('id')}",
                        "remain": tray.get("remain"),
                        "tray_weight": float(tray.get("tray_weight") or 0),
                    }
                )
            except (TypeError, ValueError):
                continue
    return trays


def extract_telemetry(merged_print, estimator):
    if not merged_print:
        return None

    state = merged_print.get("gcode_state")
    trays = extract_trays(merged_print)

    return {
        "state": state,
        "percent": merged_print.get("mc_percent"),
        "remaining_min": merged_print.get("mc_remaining_time"),
        "layer": merged_print.get("layer_num"),
        "total_layers": merged_print.get("total_layer_num"),
        "nozzle_temp": merged_print.get("nozzle_temper"),
        "bed_temp": merged_print.get("bed_temper"),
        "file": merged_print.get("subtask_name") or None,
        "grams_used_estimate": estimator.update(state, trays) if state else None,
    }


def main():
    cfg = load_config()
    estimator = GramEstimator()
    merged_print = {}  # accumulated state across the full report + all deltas since
    latest = {"data": None}

    def on_connect(client, userdata, flags, rc, properties=None):
        if str(rc) not in ("Success", "0"):
            log.error("MQTT connect failed: %s", rc)
            return
        log.info("connected to Bambu Cloud MQTT")
        client.subscribe(f"device/{cfg['serial']}/report")
        client.publish(
            f"device/{cfg['serial']}/request",
            json.dumps({"pushing": {"sequence_id": "0", "command": "pushall", "version": 1, "push_target": 1}}),
        )

    def on_disconnect(client, userdata, rc, properties=None, reason=None):
        log.warning("disconnected from MQTT (rc=%s) — paho will auto-reconnect", rc)

    def on_message(client, userdata, msg):
        try:
            report = json.loads(msg.payload)
        except json.JSONDecodeError:
            return
        p = report.get("print")
        if not p:
            return  # e.g. an empty "{}" keepalive-style message
        deep_merge(merged_print, p)
        telemetry = extract_telemetry(merged_print, estimator)
        if telemetry:
            latest["data"] = telemetry

    client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(f"u_{cfg['uid']}", cfg["access_token"])
    client.tls_set()  # default: full certificate + hostname validation
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_start()

    log.info("bridge running, posting telemetry every %ss", POST_INTERVAL_S)
    try:
        while True:
            time.sleep(POST_INTERVAL_S)
            if latest["data"] is None:
                continue
            try:
                resp = requests.post(
                    f"{cfg['worker_url'].rstrip('/')}/api/telemetry",
                    json=latest["data"],
                    headers={"X-Telemetry-Secret": cfg["telemetry_secret"]},
                    timeout=10,
                )
                if resp.status_code != 200:
                    log.warning("worker rejected telemetry: %s %s", resp.status_code, resp.text[:200])
            except requests.RequestException as e:
                log.warning("failed to post telemetry: %s", e)
    except KeyboardInterrupt:
        pass
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
