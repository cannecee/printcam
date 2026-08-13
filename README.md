# PrintCam

Bambu Lab 3D yazıcının kamerasını OBS üzerinden internete canlı yayınlamak için minimal, self-hosted bir sistem.

## Mimari

```
[Kamera] -> [OBS, RTMP push]
                 |  rtmp://localhost:1935/printer   (aynı makinede — Yol A)
                 v
        [Bu Mac: MediaMTX]
           RTMP-in  -> path "printer" -> HLS-out (fmp4, ~birkaç sn gecikme, :8888)
                 |
                 |  Cloudflare Tunnel (sadece :8888 dışarı açılır)
                 v
        https://printer.example.com/printer/index.m3u8
                 |
                 v
        [viewer/index.html]  (Cloudflare Pages / Netlify / GitHub Pages)
           hls.js ile oynatır, herkese açık
```

Önemli tasarım kararı: **sadece HLS portu (:8888) internete açılır**. RTMP girişi (:1935) hiçbir zaman tünellenmez/dışarı açılmaz. RTMP tarafında kimlik doğrulama yok, dolayısıyla dışarı açmak isteyen herkesin "printer" path'ine push edebilmesi anlamına gelir — bu yüzden RTMP portu her zaman yerel/LAN'da kalır.

Bu sistemi çalıştırma yolları:
- **Yol A — Bu Mac'te çalıştır** (önerilen, şu an aktif): OBS ve MediaMTX aynı makinede, `localhost` üzerinden konuşurlar. Aşağıdaki ana akış bu.
- **Yol B — Raspberry Pi'de çalıştır** (ileride Pi edinirsen): dosyanın ilerisinde ayrı bir bölüm var.
- **Ek — Fly.io (denendi, şu an önerilmiyor)**: en sonda, neden vazgeçildiği açıklamasıyla birlikte.

## Klasör yapısı

```
printcam/
  mediamtx.yml            # MediaMTX config (RTMP-in, HLS-out) — Yol A/B için
  setup-mac.sh              # Yol A: Homebrew ile bu Mac'te kurulum
  setup-pi.sh                 # Yol B: Raspberry Pi'de kurulum
  cloudflared-config.yml        # Yol A/B: Cloudflare Tunnel ingress örneği
  viewer/
    index.html                  # Statik viewer sayfası (hls.js + izleyici sayacı)
  worker.js                       # Cloudflare Worker: viewer/'ı servis eder + /api/heartbeat + /api/telemetry
  wrangler.jsonc                   # Worker/Pages deploy config (Durable Object binding dahil)
  bridge.py                         # Yazıcı telemetrisi: Bambu Cloud MQTT -> Worker köprüsü
  bridge-requirements.txt            # bridge.py'nin Python bağımlılıkları
  bridge_config.example.json          # bridge_config.json için şablon (gerçek değerler repoya girmez)
  setup-bridge.sh                      # bridge.py'yi launchd servisi olarak kurar
  mediamtx.fly.yml                      # Ek: Fly.io config (auth'lu) — kullanılmıyor ama duruyor
  Dockerfile                             # Ek: Fly.io imajı — kullanılmıyor ama duruyor
  fly.toml                                # Ek: Fly.io app config — kullanılmıyor ama duruyor
  README.md
```

**İzleyici sayacı:** Viewer sayfasındaki "CANLI" rozetinin yanında görünen sayı, `worker.js`'teki küçük bir Cloudflare Worker + Durable Object'ten geliyor (`/api/heartbeat`). MediaMTX'e hiç dokunmuyor — bilinçli bir tercih: MediaMTX'in kendi Control API'si (`api: yes`) tek parça bir yetki modeline sahip, salt-okunur bir alt kümesi yok (aynı kimlik bilgisiyle biri OBS'in yayınını da kesebilir), bu yüzden public/client-side bir sayfaya güvenle gömülemez. Durable Object'ler Cloudflare'in ücretsiz planında (SQLite destekli, günde 100k istek) çalışıyor. Deploy komutu artık `npx wrangler deploy` (sade `wrangler pages deploy` değil — proje artık bir `main` script içeriyor).

**Yazıcı telemetrisi:** Video'nun altındaki durum/yüzde/kalan-süre/katman/sıcaklık şeridi `bridge.py`'den geliyor — ayrıntılar aşağıda "Ek: Yazıcı Telemetrisi" bölümünde.

---

# Yol A: Bu Mac'te çalıştır

## A.1. MediaMTX'i kur ve başlat

```bash
cd printcam
./setup-mac.sh
```

Script şunları yapar (sudo gerektirmez):
- `brew install mediamtx cloudflared`
- `mediamtx.yml`'i Homebrew'un beklediği yere (`$(brew --prefix)/etc/mediamtx/mediamtx.yml`) kopyalar
- MediaMTX'i `brew services start mediamtx` ile arka plan servisi olarak başlatır — bu bir launchd Agent'tır: **sen bu Mac'e giriş yaptığında** otomatik başlar, çökerse `brew services` onu yeniden başlatır
- Port 1935 ve 8888'in dinlediğini doğrular

Doğrulama:
```bash
brew services info mediamtx          # "started" görmelisin
curl -I http://localhost:8888/printer/index.m3u8   # gerçek bir HTTP cevabı dönmeli (OBS henüz yayında değilse bile)
```

Config'i değiştirirsen (`$(brew --prefix)/etc/mediamtx/mediamtx.yml`), `./setup-mac.sh`'i tekrar çalıştırman yeterli (idempotent).

Loglar: `$(brew --prefix)/var/log/mediamtx/output.log` (ve `error.log`).

> **macOS uyku modu notu:** Mac uykuya geçerse yayın da durur. Yayın sırasında Mac'in uyumamasını istiyorsan: **System Settings → Lock Screen** (veya eski sürümlerde **Energy Saver**) içinden "Prevent automatic sleeping" ayarını aç, ya da terminalde `caffeinate -dis` çalıştır (yayın süresince açık tut). Bunlar sistem ayarı değiştirdiği için `setup-mac.sh` senin adına yapmaz.

## A.2. OBS ayarları

Settings → Stream → Service: **Custom...**

| Alan | Değer |
|---|---|
| Server | `rtmp://localhost:1935/printer` |
| Stream Key | *(boş bırak)* |

> **Not:** `mediamtx.yml` içinde tanımlı tek path adı `printer`. RTMP'de OBS, "Server" alanının path kısmı ile "Stream Key" alanını birleştirip MediaMTX'e tek bir path adı olarak gönderir. En temiz sonuç için path'i doğrudan Server alanına yaz (`.../printer`) ve Key'i boş bırak.

Settings → Output → Streaming (x264, önerilen düşük gecikme ayarları):

- **Keyframe Interval**: 1-2 saniye (HLS segment süresi 1sn olduğu için önemli)
- **CPU Usage Preset**: `veryfast`
- **Bitrate**: 2500-4000 Kbps 1080p için genelde yeterli; yükleme bant genişliğin düşükse 1500-2000 Kbps'e ve/veya 720p'ye düş
- **Profile**: `main` veya `high`

Start Streaming'e bastığında, `brew services info mediamtx` çalışırken bir publisher bağlantısı loglara düşmeli; `curl -I http://localhost:8888/printer/index.m3u8` artık `200 OK` dönmeli.

## A.3. Cloudflare Tunnel kurulumu

Amaç: bu Mac'te port yönlendirme yapmadan, `:8888` (HLS) portunu `printer.example.com` gibi bir subdomain üzerinden herkese açmak. `cloudflared` zaten `setup-mac.sh` ile kuruldu.

```bash
cloudflared tunnel login          # tarayıcıda Cloudflare hesabınla giriş, domain seç
cloudflared tunnel create printcam
```

Bu komut bir `<TUNNEL_ID>` üretir ve `~/.cloudflared/<TUNNEL_ID>.json` kimlik dosyasını oluşturur.

```bash
cloudflared tunnel route dns printcam printer.example.com
```

Bu, Cloudflare DNS'ine `printer.example.com -> <TUNNEL_ID>.cfargotunnel.com` CNAME kaydını otomatik ekler.

Repodaki `cloudflared-config.yml`'i düzenle: `<TUNNEL_ID>`, `<kullanıcı-adın>` ve `printer.example.com` yerlerini kendi değerlerinle değiştir (credentials-file için **tam/absolute yol** kullan — `~` burada genişletilmez). Sonra:

```bash
mkdir -p $(brew --prefix)/etc/cloudflared
cp cloudflared-config.yml $(brew --prefix)/etc/cloudflared/config.yml
brew services start cloudflared
```

Test:
```bash
curl -I https://printer.example.com/printer/index.m3u8
```
OBS yayın açıkken `200 OK` dönmeli.

## A.4. Viewer sayfasının deploy edilmesi

`viewer/index.html` tek başına, build gerektirmeyen statik bir dosya — ama izleyici sayacı bir Cloudflare Worker'a (`worker.js`) bağlı olduğu için bu proje **Cloudflare Workers** üzerinden deploy ediliyor (klasik Pages drag-and-drop akışıyla değil, çünkü o akış `worker.js`'i ve Durable Object binding'ini işlemez).

1. Dosyanın en üstündeki `STREAM_URL` ve (istersen) `VIEWER_COUNT_URL` sabitlerini güncelle:
   ```js
   const STREAM_URL = "https://printer.example.com/printer/index.m3u8";
   const VIEWER_COUNT_URL = "https://<senin-worker-adın>.<hesabın>.workers.dev/api/heartbeat";
   ```
2. `printcam/` klasöründen (yani `wrangler.jsonc`'un olduğu yerden):
   ```bash
   npx wrangler login      # ilk seferde, tarayıcıda Cloudflare hesabınla giriş
   npx wrangler deploy
   ```
   Bu, hem `viewer/`'ı statik asset olarak hem `worker.js`'i (izleyici sayacı) hem de Durable Object'i tek seferde deploy eder. Çıktıdaki URL (`https://<proje-adı>.<hesabın>.workers.dev`) senin public viewer adresin.

Build adımı yok, `npm install` yok — `wrangler` ilk çalıştırmada `npx` ile otomatik iner.

**Sadece video izleme, sayaç olmadan** deploy etmek istersen (daha basit): `VIEWER_COUNT_URL`'i boş string yap (`const VIEWER_COUNT_URL = "";`), rozet hiç görünmez; bu durumda `wrangler.jsonc`'daki `main`/`durable_objects` bloklarını da kaldırıp klasik statik hosting'e (Netlify/GitHub Pages/Pages drag-and-drop) dönebilirsin.

---

# Yol B: Raspberry Pi'de çalıştır (varsa)

Pi elinde varsa ve MediaMTX'i ayrı, her zaman açık bir cihazda çalıştırmak istersen bu yolu kullan. Raspberry Pi OS (64-bit) ve SSH erişimi olduğunu varsayıyoruz.

```bash
# Kendi makinende, printcam/ klasörünün olduğu yerden:
scp -r printcam pi@<pi-lan-ip>:~/printcam
ssh pi@<pi-lan-ip>
cd ~/printcam
sudo ./setup-pi.sh
```

Script en son MediaMTX arm64 sürümünü GitHub'dan indirir, `/opt/mediamtx` altına kurar, yetkisiz bir `mediamtx` sistem kullanıcısı oluşturur, systemd servisi kurar (`Restart=on-failure`, boot'ta otomatik başlar).

Doğrulama:
```bash
systemctl status mediamtx
journalctl -u mediamtx -f
curl -I http://localhost:8888/printer/index.m3u8
```

**OBS ayarları farkı:** Server alanı artık `rtmp://<pi-lan-ip>:1935/printer` olur (Pi'nin LAN IP'si) — Key yine boş. OBS'in çalıştığı bilgisayar Pi ile aynı ağda olmalı (ya da VPN üzerinden erişmeli), çünkü RTMP portu tünellenmiyor.

**Cloudflare Tunnel farkı:** `cloudflared`'i Pi'de arm64 `.deb` paketiyle kurup systemd servisi olarak (`cloudflared service install`) çalıştırırsın; kimlik dosyası `/root/.cloudflared/<TUNNEL_ID>.json` altına gider (root olarak systemd servisi çalıştığı için). Detaylar için Yol A'daki Cloudflare Tunnel adımlarının Pi'ye uyarlanmış hali aynı mantıkla işler.

Diğer her şey (mediamtx.yml, viewer deploy) Yol A ile birebir aynı.

---

# Ek: Yazıcı Telemetrisi

Video altındaki durum/ilerleme/kalan süre/katman/sıcaklık şeridi, kameradan tamamen bağımsız ayrı bir sistem: `bridge.py`, Bambu Lab'ın **cloud** MQTT'sine bağlanıp yazıcı durumunu okur ve `worker.js`'e (`/api/telemetry`) iletir; viewer sayfası bunu mevcut izleyici-sayacı heartbeat'iyle aynı yanıtın içinde alır.

**Neden LAN değil de cloud?** Bu proje LAN Only + yerel MQTT ile başladı, ama bridge'in çalıştığı makine (bu Mac) yazıcıyla asla aynı WiFi'de olmuyor — yerel MQTT (`{printer-ip}:8883`) LAN dışından hiç erişilemez. Yazıcıda LAN Only kapalı olduğu için Bambu Cloud'un resmi MQTT'sini (`us.mqtt.bambulab.com:8883`) kullanıyoruz.

**Şifren hiç kullanılmadı/saklanmadı.** Giriş, Bambu'nun **e-posta doğrulama kodu** akışıyla yapıldı: hesabına bir defalık kod isteği gönderildi, kodu bir kere kullanıp ~1 yıl geçerli bir `accessToken` alındı. `bridge.py` sadece bu token'ı okur — hesap şifresiyle hiçbir bağlantısı yok. Token süresi dolarsa aynı akışı tekrarlaman gerekir (aşağıda).

## Neler var, neler yok

Bambu'nun resmi/topluluk dokümantasyonundan (`Doridian/OpenBambuAPI`) doğrulanan alanlar: baskı durumu (`gcode_state`), yüzde, kalan süre, katman, nozzle/tabla sıcaklığı, dosya adı. **Gram cinsinden anlık malzeme kullanımı için resmi bir alan yok** — en yakın şey AMS makaralarındaki `tray_weight` (kullanıcının AMS'te girdiği makara ağırlığı) ve `remain` (makara doluluk %'si). `bridge.py` bu ikisinden baskı başlangıcına göre bir **tahmini** gram hesabı çıkarıyor, ama makara ağırlığını AMS'te girmediysen (şu an senin printer'ında öyle — `tray_weight: 0`) bu satır hiç görünmez, uydurma bir sayı göstermek yerine.

## Kurulum (tekrar/yeni printer için)

1. **Cloud token al** (bir kerelik, ~1 yıl geçerli):
   ```bash
   # Kod iste
   curl -X POST "https://api.bambulab.com/v1/user-service/user/sendemail/code" \
     -H "Content-Type: application/json" \
     -d '{"email":"<bambu-hesap-emailin>","type":"codeLogin"}'
   # E-postana gelen kodu al, sonra:
   curl -X POST "https://api.bambulab.com/v1/user-service/user/login" \
     -H "Content-Type: application/json" \
     -d '{"account":"<bambu-hesap-emailin>","code":"<gelen-kod>"}'
   ```
   Cevaptaki `accessToken`'ı not al.

2. **uid'ini öğren:**
   ```bash
   curl "https://api.bambulab.com/v1/design-user-service/my/preference" \
     -H "Authorization: Bearer <accessToken>"
   ```
   Cevaptaki `uid` alanı.

3. **`bridge_config.json` oluştur:**
   ```bash
   cd printcam
   cp bridge_config.example.json bridge_config.json
   ```
   İçini doldur: `uid`, `serial` (yazıcının seri no'su — Bambu Studio'da ya da printer ekranında), `access_token` (1. adım), `worker_url` (deploy edilmiş Worker adresin), `telemetry_secret` (aşağıya bak).

4. **Telemetry secret'ı Worker'a kaydet** (bridge_config.json'daki değerle aynı olmalı):
   ```bash
   npx wrangler secret put TELEMETRY_SECRET
   ```

5. **Bridge'i kur ve başlat:**
   ```bash
   ./setup-bridge.sh
   ```
   Bu, bir Python venv oluşturur ve bridge'i bir launchd LaunchAgent olarak kaydeder — Mac'e girişte otomatik başlar, çökerse yeniden başlar (mediamtx/cloudflared'in `brew services` ile çalışması gibi).

Doğrulama:
```bash
tail -f printcam/.bridge-logs/output.log printcam/.bridge-logs/error.log
```
"connected to Bambu Cloud MQTT" görmelisin, sonra birkaç saniyede bir "posting telemetry" benzeri aktivite.

## Sorun giderme (telemetri)

- **Şerit hiç görünmüyor:** `worker.js`'in `/api/heartbeat` yanıtında `telemetry: null` mü dönüyor kontrol et (`curl -X POST .../api/heartbeat -d '{"id":"test"}'`). `null` ise: bridge çalışmıyor olabilir (`.bridge-logs/error.log`'a bak) ya da 60 saniyeden uzun süredir veri gelmemiş (bridge durmuş/Mac uykuda).
- **`bridge_config.json bulunamadı` hatası:** `cp bridge_config.example.json bridge_config.json` yapıp gerçek değerleri girmemişsin.
- **401/unauthorized (telemetry post reddediliyor):** `bridge_config.json`'daki `telemetry_secret` ile Worker'a `wrangler secret put TELEMETRY_SECRET` ile girdiğin değer birebir aynı değil.
- **Token süresi doldu (yaklaşık 1 yıl sonra):** "Kurulum" bölümündeki 1-2. adımları tekrarlayıp `bridge_config.json`'daki `access_token`'ı güncelle, bridge'i yeniden başlat (`launchctl unload/load ~/Library/LaunchAgents/com.printcam.bridge.plist`).
- **Gram tahmini hiç çıkmıyor:** Beklenen davranış, AMS'te makara ağırığı (spool weight) girilmemişse. Bambu Studio/Handy üzerinden AMS makaralarına ağırlık girersen bir sonraki baskıda görünür.

---

## Sorun giderme

### OBS'te siyah ekran / önizleme boş
- Kamerayı Bambu yazıcıdan alıyorsan (RTSP/USB video capture vb.), OBS'te doğru kaynağı (Video Capture Device / Media Source) seçtiğinden emin ol; "Kaynak Aktif" (Activate) durumunda mı kontrol et.
- Donanım encoder (VideoToolbox/NVENC/QuickSync) sürücü sorunu yaşatıyorsa Settings → Output → Encoder'ı `x264` (yazılım) yap ve tekrar dene.
- "Start Streaming" ile "Start Recording"i karıştırma.

### Stream MediaMTX'e bağlanmıyor
- Server/Stream Key eşleşmesini kontrol et: path tam olarak `printer` olmalı.
- **Yol A (Mac):** `brew services info mediamtx` ile servisin `started` olduğunu doğrula; `$(brew --prefix)/var/log/mediamtx/output.log` içinde publish denemesi loglanıyor mu bak.
- **Yol B (Pi):** `sudo systemctl status mediamtx` ile servisin çalıştığını doğrula; `journalctl -u mediamtx -f` ile publish denemesi loglanıyor mu bak. Port 1935'in Pi'nin LAN arayüzünde açık olduğunu doğrula: `sudo ss -tlnp | grep 1935`.
- Cloudflare Tunnel yalnızca :8888'i taşır — RTMP bağlantı sorunlarının tüneli ile ilgisi yok.

### Bant genişliği / gecikme sorunları
- OBS bitrate'ini düşür (1500-2500 Kbps aralığını dene), gerekiyorsa çözünürlüğü 720p'ye indir.
- Keyframe interval'ı 1-2sn'de tut.
- MediaMTX yalnızca remux yapar (transcode etmez), CPU yükü neredeyse hiç olmaz — darboğaz genelde yukarı yönlü (upload) internet bant genişliğidir.

### Yayın aniden duruyor (Yol A, Mac)
- Mac uykuya geçmiş olabilir — "macOS uyku modu notu"na bak, `caffeinate` çalıştır ya da Enerji ayarlarını değiştir.
- `brew services info mediamtx` ile servisin hâlâ `started` olduğunu doğrula; değilse `brew services restart mediamtx`.

### Viewer sayfası "bağlantı koptu" durumunda takılı kalıyor
- Tarayıcı konsolunu aç (F12): hls.js CDN'den yüklenemiyor olabilir, ya da `STREAM_URL` yanlış/CORS hatası veriyor olabilir.
- `hlsAllowOrigins: ["*"]` `mediamtx.yml`'de tanımlı — kaldırma.
- `STREAM_URL`'i tarayıcıda doğrudan aç — bir `.m3u8` playlist metni dönmeli.

### iPhone/Safari'de oynatma bozuk veya hiç açılmıyor
`mediamtx.yml`'de `hlsVariant: fmp4` kullanılıyor, `lowLatency` değil — bu bilinçli bir tercih. LL-HLS'te parçaların (part) hedef süresi sabit kalmak zorunda (Apple'ın spesifikasyonu), ama MediaMTX bunu gerçek zamanlı gözlemlenen verilerden hesaplıyor ve canlı bir kamera akışında bu değer zamanla kayar — loglarda `part duration changed ... this will cause an error in iOS clients` uyarısı olarak görünür ve gerçekten Safari/iPhone'da oynatmayı bozabilir. `hlsVariant`'ı yanlışlıkla `lowLatency`'ye geri çevirdiysen (elle config düzenleyerek), bu sorunun geri geldiğini gösterir — `fmp4`'e döndür.

---

## Güvenlik notu

HLS çıktısı kimlik doğrulamasız ve herkese açık — URL'i bilen herkes izleyebilir. Erişimi kısıtlamak istersen, `printer.example.com` hostname'i için Cloudflare Access (Zero Trust) ile bir giriş ekranı ekleyebilirsin.

---

## Ek: Fly.io denemesi (şu an önerilmiyor)

`mediamtx.fly.yml`, `Dockerfile` ve `fly.toml` bu klasörde duruyor ama aktif olarak kullanılmıyor. Deneyip gerçek bir sorunla karşılaştık, buraya not düşüyoruz ki tekrar denenirse zaman kaybedilmesin:

**Sorun:** Fly.io'nun *shared* (paylaşımlı, ücretsiz) IPv4 adresi yalnızca HTTP(S) (80/443) veya TLS'li portları public olarak yönlendirebiliyor. RTMP TLS'siz olduğu için (`rtmpEncryption: no`) port 1935'te trafik Fly'ın edge proxy'sine TCP seviyesinde ulaşıyor (`nc` ile bağlantı testi başarılı) ama gerçek veriye çevrilmiyor — RTMP handshake'i hiç MediaMTX'e ulaşmıyor (`Cannot read RTMP handshake response` / `Connection reset by peer`). Bunu hem OBS'te hem ffmpeg ile doğrudan test ederek doğruladık; Fly'ın kendi WireGuard mesh'i üzerinden makineye direkt bağlanınca (public proxy'yi atlayarak) her şey sorunsuz çalıştı — yani MediaMTX'in kendisinde hiçbir sorun yok, tamamen Fly'ın public TCP routing katmanında.

**Çözüm (denenmedi, maliyetli):** Dedicated (özel) bir IPv4 adresi almak — **$2/ay**:
```bash
flyctl ips allocate-v4 --app <app-adı>   # --shared OLMADAN
```
Bu, kullanıcının "maliyeti minimumda tut" tercihiyle çeliştiği için şu an uygulanmadı, Yol A'ya (Mac) dönüldü.

Yeniden denemek istersen: `flyctl apps create <yeni-ad>`, `fly.toml`'daki `app` adını güncelle, `flyctl secrets set MTX_AUTHINTERNALUSERS_0_PASS=...`, `flyctl deploy`, sonra yukarıdaki dedicated IPv4 komutunu çalıştır ve OBS'i o IP'ye yönlendir (`?user=&pass=` query param sözdizimini kullan — `user:pass@host` MediaMTX'te RTMP için çalışmıyor).
