# Quest3 Godot Project (3D Stereo + External Texture)

Bu proje, **2D split/overlay kullanmadan** kamera görüntüsünü 3D uzayda mesh üzerine basarak stereo üretmek için düzenlenmiştir.

## Mimari Özeti

- Ana sahne: `res://scenes/StereoViewScene.tscn`
  - `Node3D` tabanlıdır (2D UI yok).
  - Aynı noktada çalışan iki `SubViewport` içerir:
    - `LeftEyeViewport`
    - `RightEyeViewport`
  - Her viewport kendi 3D mesh’ine aynı kamera kaynağını basar.
  - Ana (default) ekranda tam ekran olarak tek göz çıktısı (`UseLeftEyeForMainDisplay`) gösterilir.

- Ana script: `scripts/stereo/Stereo3DViewer.cs`
  - Android singleton bridge: `QuestExternalTexture`
  - Akış: `configure_external_texture(texture_id, w, h)` + `set_stream_url(url)` + `start_stream()`
  - Fallback: RTSP/HLS arasında otomatik geçiş (ilk URL başarısızsa alternatif protokol denenir)
  - Stereo UV shift/zoom ayarları shader ile uygulanır.

## Bu Akışta Neler Yok?

- Ek media middleware yok; yalnız network external texture hattı var.
- Tablet cihazın yerel kamera erişimi yok.
- Ortada çizgi/debug yazısı gibi 2D overlay yok.

## Hızlı Başlangıç

1. Projeyi Godot’ta aç.
2. Laptopta tüm canlı test altyapısını tek komutla başlat:

  ```bash
  cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
  ./start.sh
  ```

  Bu komut sender + RTSP server başlatır, uygun olduğunda log pencerelerini açar.

  Dilersen yalnız sender scriptini de doğrudan çalıştırabilirsin:

  ```bash
  cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
  ./tools/stream/start_rtsp_sender.sh
  ```

  Not: Script otomatik olarak ilk uygun (loopback olmayan) kamera cihazını seçer.
  Gerekirse manuel cihaz verebilirsin: `./tools/stream/start_rtsp_sender.sh /dev/video1`

3. Ana sahneyi çalıştır: `res://scenes/StereoViewScene.tscn`
4. Sahnede gömülü URL:

  - `rtsp://192.168.2.207:8554/quest3` (başarısız olursa otomatik HLS denenir)

  IP değişirse `NetworkStreamUrl` değerini yeni laptop IP ile güncelle.
5. Android plugin tarafında `QuestExternalTexture` singleton'ı aktif olmalı.

## Sender Kontrol Komutları (Laptop)

Durum:

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./tools/stream/status_rtsp_sender.sh
```

Tam kapatma (önerilen):

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./stop.sh
```

Versiyonlu APK üretimi (sıralı klasör):

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./build_versioned_apk.sh
```

Bu komut her çalışmada `build/android/releases/` altında sıradaki klasörü oluşturur
(`v1.0.1`, `v1.0.2`, ...), APK'yı içine koyar ve ayrıca güncel kopyayı
`build/android/Quest3-tablet-debug.apk` yoluna da yazar.

Wi‑Fi ADB log bağlantısı (yardımcı script):

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./tools/adb/connect_wifi_adb.sh
```

Bu script pair/connect adımlarını sorar ve son endpoint'i kaydeder.
Ardından canlı başlatma için:

```bash
./start.sh --camera usb
```

> Önemli: Komutlarda `<TABLET_IP>` gibi yer tutucuları **olduğu gibi yazma**.
> Gerçek değerle değiştir (örn: `192.168.2.55:38947`).

Durdur:

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./tools/stream/stop_rtsp_sender.sh
```

FFmpeg kurulu değilse:

```bash
sudo apt update
sudo apt install -y ffmpeg v4l-utils
```

Docker kurulu/deaktifse:

```bash
sudo apt update
sudo apt install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

> Son komuttan sonra oturumu kapatıp tekrar aç.

## Ağ Notu (Wi‑Fi / Hotspot)

- Bu akış **aynı yerel ağ** (LAN) içinde çalışır, internet kotası tüketmez.
- Wi‑Fi sinyali zayıfsa gecikme/artifakt olabilir.
- Gecikmeyi azaltmak için:
  - mümkünse 5 GHz kullan,
  - cihazları AP/router’a yakın tut,
  - gerekirse mobil hotspot ile kısa mesafe test yap.

## Not

- Quest3 hedefi için bu yapı VR’ye uygun 3D sahne temeli sağlar.
- Bu projede **yalnızca external texture** hedeflenir; Android singleton yoksa görüntü gelmez.
