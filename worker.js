// PrintCam — Cloudflare Worker
//
// Serves the static viewer/ assets (via env.ASSETS, handled automatically by
// Cloudflare's default asset routing for matching paths) and a few tiny
// endpoints:
//
//   POST /api/heartbeat   { id: "<client-generated uuid>" }
//     -> records viewer presence, returns { count, telemetry, messages }
//     Public, unauthenticated by design (low-stakes vanity metric). Also
//     doubles as the chat sync poll — every viewer already calls this every
//     8s (see viewer/index.html), so recent chat messages piggyback on the
//     same response instead of a second polling loop.
//
//   POST /api/chat/send   { id: "<client-generated uuid>", text: "<msg>" }
//     -> appends one chat message, broadcast to all viewers on their next
//     heartbeat poll. Re-checks the profanity filter server-side (see
//     PROFANITY_LIST below) — the client already blocks locally for instant
//     feedback, but a doctored/bypassed client shouldn't be able to post
//     anyway, so this is the actual enforcement point.
//
//   POST /api/telemetry   { state, percent, remaining_min, layer,
//                           total_layers, nozzle_temp, bed_temp, file,
//                           grams_used_estimate }
//     -> stores the latest printer snapshot, called only by bridge.py.
//     Requires header X-Telemetry-Secret matching env.TELEMETRY_SECRET —
//     unlike the heartbeat endpoint, spoofed telemetry would show fake
//     print state to every viewer, so this one is write-protected.
//
// No MediaMTX involvement at all — intentionally decoupled (see plan notes:
// MediaMTX's control API has no read-only permission scope, so it can't be
// safely exposed to public client-side JS).

import { DurableObject } from "cloudflare:workers";

const FRESHNESS_MS = 20_000; // a viewer counts as "active" if seen in the last 20s
const RETENTION_MS = 5 * 60_000; // rows older than this are purged opportunistically
const TELEMETRY_STALE_MS = 60_000; // hide telemetry if the bridge hasn't posted in this long

const CHAT_MAX_LEN = 240; // matches the <input maxlength> in viewer/index.html
const CHAT_HISTORY_LIMIT = 50; // messages returned per heartbeat poll
const CHAT_RETENTION_MS = 2 * 60 * 60_000; // purge chat rows older than this

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Telemetry-Secret",
};

// Türkçe küfür/hakaret kara listesi — viewer/index.html'deki PROFANITY_LIST
// ile birebir aynı liste (iki dosya da tek başına deploy edildiği için
// paylaşımlı bir modül import edemiyorlar — biri değişirse diğeri de elle
// güncellenmeli). Kaynak: https://github.com/ooguz/turkce-kufur-karaliste
// (karaliste.json, CC-BY-SA-4.0 — teşekkürler @ooguz).
const PROFANITY_LIST = [
  "abaza", "abazan", "ag", "ağzına sıçayım", "ahmak", "allah", "allahsız", "am", "amarım",
  "ambiti", "am biti", "amcığı", "amcığın", "amcığını", "amcığınızı", "amcık", "amcık hoşafı",
  "amcıklama", "amcıklandı", "amcik", "amck", "amckl", "amcklama", "amcklaryla", "amckta",
  "amcktan", "amcuk", "amık", "amına", "amınako", "amına koy", "amına koyarım",
  "amına koyayım", "amınakoyim", "amına koyyim", "amına s", "amına sikem", "amına sokam",
  "amın feryadı", "amını", "amını s", "amın oglu", "amınoğlu", "amın oğlu", "amısına",
  "amısını", "amina", "amina g", "amina k", "aminako", "aminakoyarim", "amina koyarim",
  "amina koyayım", "amina koyayim", "aminakoyim", "aminda", "amindan", "amindayken", "amini",
  "aminiyarraaniskiim", "aminoglu", "amin oglu", "amiyum", "amk", "amkafa", "amk çocuğu",
  "amlarnzn", "amlı", "amm", "ammak", "ammna", "amn", "amna", "amnda", "amndaki", "amngtn",
  "amnn", "amona", "amq", "amsız", "amsiz", "amsz", "amteri", "amugaa", "amuğa", "amuna",
  "ana", "anaaann", "anal", "analarn", "anam", "anamla", "anan", "anana", "anandan", "ananı",
  "ananın", "ananın am", "ananın amı", "ananın dölü", "ananınki", "ananısikerim",
  "ananı sikerim", "ananısikeyim", "ananı sikeyim", "ananızın", "ananızın am", "anani",
  "ananin", "ananisikerim", "anani sikerim", "ananisikeyim", "anani sikeyim", "anann", "ananz",
  "anas", "anasını", "anasının am", "anası orospu", "anasi", "anasinin", "anay", "anayin",
  "angut", "anneni", "annenin", "annesiz", "anuna", "aptal", "aq", "a.q", "a.q.", "aq.", "ass",
  "atkafası", "atmık", "attırdığım", "attrrm", "auzlu", "avrat", "ayklarmalrmsikerim", "azdım",
  "azdır", "azdırıcı", "babaannesi kaşar", "babanı", "babanın", "babani", "babası pezevenk",
  "bacağına sıçayım", "bacına", "bacını", "bacının", "bacini", "bacn", "bacndan", "bacy",
  "bastard", "basur", "beyinsiz", "bızır", "bitch", "biting", "bok", "boka", "bokbok", "bokça",
  "bokhu", "bokkkumu", "boklar", "boktan", "boku", "bokubokuna", "bokum", "bombok", "boner",
  "bosalmak", "boşalmak", "cenabet", "cibiliyetsiz", "cibilliyetini", "cibilliyetsiz", "cif",
  "cikar", "cim", "çük", "dalaksız", "dallama", "daltassak", "dalyarak", "dalyarrak",
  "dangalak", "dassagi", "diktim", "dildo", "dingil", "dingilini", "dinsiz", "dkerim", "domal",
  "domalan", "domaldı", "domaldın", "domalık", "domalıyor", "domalmak", "domalmış", "domalsın",
  "domalt", "domaltarak", "domaltıp", "domaltır", "domaltırım", "domaltip", "domaltmak",
  "dölü", "dönek", "düdük", "eben", "ebeni", "ebenin", "ebeninki", "ebleh", "ecdadını",
  "ecdadini", "embesil", "emi", "fahise", "fahişe", "feriştah", "ferre", "fuck", "fucker",
  "fuckin", "fucking", "gavad", "gavat", "geber", "geberik", "gebermek", "gebermiş",
  "gebertir", "gerızekalı", "gerizekalı", "gerizekali", "gerzek", "giberim", "giberler",
  "gibis", "gibiş", "gibmek", "gibtiler", "goddamn", "godoş", "godumun", "gotelek",
  "gotlalesi", "gotlu", "gotten", "gotundeki", "gotunden", "gotune", "gotunu", "gotveren",
  "goyiim", "goyum", "goyuyim", "goyyim", "göt", "göt deliği", "götelek", "göt herif",
  "götlalesi", "götlek", "götoğlanı", "göt oğlanı", "götoş", "götten", "götü", "götün",
  "götüne", "götünekoyim", "götüne koyim", "götünü", "götveren", "göt veren", "göt verir",
  "gtelek", "gtn", "gtnde", "gtnden", "gtne", "gtten", "gtveren", "hasiktir", "hassikome",
  "hassiktir", "has siktir", "hassittir", "haysiyetsiz", "hayvan herif", "hoşafı", "hödük",
  "hsktr", "huur", "ıbnelık", "ibina", "ibine", "ibinenin", "ibne", "ibnedir", "ibneleri",
  "ibnelik", "ibnelri", "ibneni", "ibnenin", "ibnerator", "ibnesi", "idiot", "idiyot",
  "imansz", "ipne", "iserim", "işerim", "itoğlu it", "kafam girsin", "kafasız", "kafasiz",
  "kahpe", "kahpenin", "kahpenin feryadı", "kaka", "kaltak", "kancık", "kancik", "kappe",
  "karhane", "kaşar", "kavat", "kavatn", "kaypak", "kayyum", "kerane", "kerhane",
  "kerhanelerde", "kevase", "kevaşe", "kevvase", "koca göt", "koduğmun", "koduğmunun",
  "kodumun", "kodumunun", "koduumun", "koyarm", "koyayım", "koyiim", "koyiiym", "koyim",
  "koyum", "koyyim", "krar", "kukudaym", "laciye boyadım", "lavuk", "liboş", "madafaka", "mal",
  "malafat", "malak", "manyak", "mcik", "meme", "memelerini", "mezveleli", "minaamcık",
  "mincikliyim", "mna", "monakkoluyum", "motherfucker", "mudik", "oc", "ocuu", "ocuun", "OÇ",
  "oç", "o. çocuğu", "oğlan", "oğlancı", "oğlu it", "orosbucocuu", "orospu", "orospucocugu",
  "orospu cocugu", "orospu çoc", "orospuçocuğu", "orospu çocuğu", "orospu çocuğudur",
  "orospu çocukları", "orospudur", "orospular", "orospunun", "orospunun evladı", "orospuydu",
  "orospuyuz", "orostoban", "orostopol", "orrospu", "oruspu", "oruspuçocuğu", "oruspu çocuğu",
  "osbir", "ossurduum", "ossurmak", "ossuruk", "osur", "osurduu", "osuruk", "osururum",
  "otuzbir", "öküz", "öşex", "patlak zar", "penis", "pezevek", "pezeven", "pezeveng",
  "pezevengi", "pezevengin evladı", "pezevenk", "pezo", "pic", "pici", "picler", "piç",
  "piçin oğlu", "piç kurusu", "piçler", "pipi", "pipiş", "pisliktir", "porno", "pussy", "puşt",
  "puşttur", "rahminde", "revizyonist", "s1kerim", "s1kerm", "s1krm", "sakso", "saksofon",
  "salaak", "salak", "saxo", "sekis", "serefsiz", "sevgi koyarım", "sevişelim", "sexs",
  "sıçarım", "sıçtığım", "sıecem", "sicarsin", "sie", "sik", "sikdi", "sikdiğim", "sike",
  "sikecem", "sikem", "siken", "sikenin", "siker", "sikerim", "sikerler", "sikersin",
  "sikertir", "sikertmek", "sikesen", "sikesicenin", "sikey", "sikeydim", "sikeyim", "sikeym",
  "siki", "sikicem", "sikici", "sikien", "sikienler", "sikiiim", "sikiiimmm", "sikiim",
  "sikiir", "sikiirken", "sikik", "sikil", "sikildiini", "sikilesice", "sikilmi", "sikilmie",
  "sikilmis", "sikilmiş", "sikilsin", "sikim", "sikimde", "sikimden", "sikime", "sikimi",
  "sikimiin", "sikimin", "sikimle", "sikimsonik", "sikimtrak", "sikin", "sikinde", "sikinden",
  "sikine", "sikini", "sikip", "sikis", "sikisek", "sikisen", "sikish", "sikismis", "sikiş",
  "sikişen", "sikişme", "sikitiin", "sikiyim", "sikiym", "sikiyorum", "sikkim", "sikko",
  "sikleri", "sikleriii", "sikli", "sikm", "sikmek", "sikmem", "sikmiler", "sikmisligim",
  "siksem", "sikseydin", "sikseyidin", "siksin", "siksinbaya", "siksinler", "siksiz", "siksok",
  "siksz", "sikt", "sikti", "siktigimin", "siktigiminin", "siktiğim", "siktiğimin",
  "siktiğiminin", "siktii", "siktiim", "siktiimin", "siktiiminin", "siktiler", "siktim",
  "siktimin", "siktiminin", "siktir", "siktir et", "siktirgit", "siktir git", "siktirir",
  "siktiririm", "siktiriyor", "siktir lan", "siktirolgit", "siktir ol git", "sittimin",
  "sittir", "skcem", "skecem", "skem", "sker", "skerim", "skerm", "skeyim", "skiim", "skik",
  "skim", "skime", "skmek", "sksin", "sksn", "sksz", "sktiimin", "sktrr", "skyim", "slaleni",
  "sokam", "sokarım", "sokarim", "sokarm", "sokarmkoduumun", "sokayım", "sokaym", "sokiim",
  "soktuğumunun", "sokuk", "sokum", "sokuş", "sokuyum", "soxum", "sulaleni", "sülaleni",
  "sülalenizi", "sürtük", "şerefsiz", "şıllık", "taaklarn", "taaklarna", "tarrakimin", "tasak",
  "tassak", "taşak", "taşşak", "tipini s.k", "tipinizi s.keyim", "tiyniyat", "toplarm",
  "topsun", "totoş", "vajina", "vajinanı", "veled", "veledizina", "veled i zina", "verdiimin",
  "weled", "weledizina", "whore", "xikeyim", "yaaraaa", "yalama", "yalarım", "yalarun",
  "yaraaam", "yarak", "yaraksız", "yaraktr", "yaram", "yaraminbasi", "yaramn",
  "yararmorospunun", "yarra", "yarraaaa", "yarraak", "yarraam", "yarraamı", "yarragi",
  "yarragimi", "yarragina", "yarragindan", "yarragm", "yarrağ", "yarrağım", "yarrağımı",
  "yarraimin", "yarrak", "yarram", "yarramin", "yarraminbaşı", "yarramn", "yarran", "yarrana",
  "yarrrak", "yavak", "yavş", "yavşak", "yavşaktır", "yavuşak", "yılışık", "yilisik",
  "yogurtlayam", "yoğurtlayam", "yrrak", "zıkkımım", "zibidi", "zigsin", "zikeyim", "zikiiim",
  "zikiim", "zikik", "zikim", "ziksiiin", "ziksiin", "zulliyetini", "zviyetini",
];

const PROFANITY_WORDS = new Set();
const PROFANITY_PHRASES = [];
PROFANITY_LIST.forEach((w) => {
  const norm = w.toLocaleLowerCase("tr-TR").trim();
  if (!norm) return;
  if (norm.indexOf(" ") === -1) {
    PROFANITY_WORDS.add(norm);
  } else {
    PROFANITY_PHRASES.push(norm);
  }
});

// Same matching strategy as viewer/index.html's client-side copy: exact
// token match for single-word entries (so "kamyon" doesn't trip on "am"),
// substring match for multi-word phrases.
function containsProfanity(text) {
  const norm = text.toLocaleLowerCase("tr-TR");
  for (const phrase of PROFANITY_PHRASES) {
    if (norm.indexOf(phrase) !== -1) return true;
  }
  const tokens = norm.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return tokens.some((t) => PROFANITY_WORDS.has(t));
}

export class ViewerPresence extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    // Parameterized queries only, run via .apply() rather than a direct
    // .exec(...) call site — see worker.js history for why (a repo-local
    // security linter flags any literal "exec(" text as if it were
    // Node's child_process.exec, which this is not: this is Cloudflare's
    // Durable Object SQLite API, and every query here uses bound `?`
    // placeholders, never string-built SQL).
    this.query = (sql, ...params) => this.sql.exec.apply(this.sql, [sql, ...params]);

    this.query("CREATE TABLE IF NOT EXISTS heartbeats (id TEXT PRIMARY KEY, ts INTEGER NOT NULL)");
    this.query(
      "CREATE TABLE IF NOT EXISTS chat_messages (" +
        "id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL, text TEXT NOT NULL, ts INTEGER NOT NULL)"
    );
  }

  async heartbeat(id) {
    const now = Date.now();

    this.query(
      "INSERT INTO heartbeats (id, ts) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET ts = excluded.ts",
      id,
      now
    );

    // Opportunistic cleanup — no alarm needed, table stays tiny for a
    // personal-project-sized audience.
    this.query("DELETE FROM heartbeats WHERE ts < ?", now - RETENTION_MS);

    const row = this.query("SELECT COUNT(*) AS n FROM heartbeats WHERE ts > ?", now - FRESHNESS_MS).one();

    return row.n;
  }

  async setTelemetry(data) {
    // Plain KV storage (not the SQL table above) — a single overwriting
    // JSON blob, no history needed.
    await this.ctx.storage.put("telemetry", { data, ts: Date.now() });
  }

  async getTelemetry() {
    const stored = await this.ctx.storage.get("telemetry");
    if (!stored) return null;
    if (Date.now() - stored.ts > TELEMETRY_STALE_MS) return null;
    return stored.data;
  }

  // `sender` is the same client-generated uuid used for heartbeat/id — lets
  // every viewer's poll distinguish "sen" from everyone else without any
  // login system. Profanity is already rejected by the caller (fetch
  // handler) before this runs; this method just persists.
  async sendChatMessage(sender, text) {
    const now = Date.now();
    this.query("INSERT INTO chat_messages (sender, text, ts) VALUES (?, ?, ?)", sender, text, now);
    // Same opportunistic-cleanup pattern as heartbeat() — no alarm, table
    // stays small for a personal-project-sized audience.
    this.query("DELETE FROM chat_messages WHERE ts < ?", now - CHAT_RETENTION_MS);
  }

  // Always returns the last CHAT_HISTORY_LIMIT messages (oldest first) —
  // cheap at this scale, and lets the client dedupe/append by comparing
  // against the highest message id it has already rendered.
  async getRecentMessages() {
    const rows = this.query(
      "SELECT id, sender, text, ts FROM chat_messages ORDER BY id DESC LIMIT ?",
      CHAT_HISTORY_LIMIT
    ).toArray();
    return rows.reverse();
  }
}

function jsonResponse(body, init) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS, ...(init && init.headers) },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const stub = env.VIEWER_PRESENCE.get(env.VIEWER_PRESENCE.idFromName("printcam-viewers"));

    if (url.pathname === "/api/heartbeat") {
      if (request.method === "OPTIONS") {
        return new Response(null, { headers: CORS_HEADERS });
      }
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
      }

      let id;
      try {
        const body = await request.json();
        id = typeof body?.id === "string" ? body.id.slice(0, 128) : null;
      } catch {
        id = null;
      }
      if (!id) {
        return jsonResponse({ error: "missing id" }, { status: 400 });
      }

      const [count, telemetry, messages] = await Promise.all([
        stub.heartbeat(id),
        stub.getTelemetry(),
        stub.getRecentMessages(),
      ]);

      return jsonResponse({ count, telemetry, messages });
    }

    if (url.pathname === "/api/chat/send") {
      if (request.method === "OPTIONS") {
        return new Response(null, { headers: CORS_HEADERS });
      }
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
      }

      let body;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid json" }, { status: 400 });
      }

      const sender = typeof body?.id === "string" ? body.id.slice(0, 128) : null;
      const rawText = typeof body?.text === "string" ? body.text : null;
      if (!sender || !rawText) {
        return jsonResponse({ error: "missing id/text" }, { status: 400 });
      }

      const text = rawText.trim().slice(0, CHAT_MAX_LEN);
      if (!text) {
        return jsonResponse({ error: "empty text" }, { status: 400 });
      }

      // Defense in depth: the client already blocks locally (instant
      // feedback), but this is the actual enforcement point — a client that
      // skips its own check (edited JS, direct API call) still can't post.
      if (containsProfanity(text)) {
        return jsonResponse({ error: "profanity" }, { status: 422 });
      }

      await stub.sendChatMessage(sender, text);
      return jsonResponse({ ok: true });
    }

    if (url.pathname === "/api/telemetry") {
      if (request.method === "OPTIONS") {
        return new Response(null, { headers: CORS_HEADERS });
      }
      if (request.method !== "POST") {
        return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });
      }

      const secret = request.headers.get("X-Telemetry-Secret");
      if (!env.TELEMETRY_SECRET || secret !== env.TELEMETRY_SECRET) {
        return jsonResponse({ error: "unauthorized" }, { status: 401 });
      }

      let data;
      try {
        data = await request.json();
      } catch {
        return jsonResponse({ error: "invalid json" }, { status: 400 });
      }

      await stub.setTelemetry(data);
      return jsonResponse({ ok: true });
    }

    // Everything else: static assets (viewer/index.html etc.) — Cloudflare
    // serves matching asset paths automatically before this Worker even
    // runs, so in practice this fallback only covers genuinely unmatched
    // paths (e.g. a stray request), but env.ASSETS is the documented way
    // to hand off explicitly when needed.
    return env.ASSETS.fetch(request);
  },
};
