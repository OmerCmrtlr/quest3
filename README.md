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
  - Fallback: yok (external texture zorunlu)
  - Stereo UV shift/zoom ayarları shader ile uygulanır.

## Bu Akışta Neler Yok?

- Ek media middleware yok; yalnız network external texture hattı var.
- Tablet cihazın yerel kamera erişimi yok.
- Ortada çizgi/debug yazısı gibi 2D overlay yok.

## Hızlı Başlangıç

1. Projeyi Godot’ta aç.
2. Laptopta sender başlat (RTSP):

  ```bash
  cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
  ./tools/stream/start_rtsp_sender.sh /dev/video0
  ```

3. Ana sahneyi çalıştır: `res://scenes/StereoViewScene.tscn`
4. Sahnede gömülü URL:

  - `rtsp://192.168.2.207:8554/quest3`

  IP değişirse `NetworkStreamUrl` değerini yeni laptop IP ile güncelle.
5. Android plugin tarafında `QuestExternalTexture` singleton'ı aktif olmalı.

## Sender Kontrol Komutları (Laptop)

Durum:

```bash
cd /home/bnfnc/Projects/StereoViewQuest3/quest-3
./tools/stream/status_rtsp_sender.sh
```

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
