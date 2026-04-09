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
2. Ana sahneyi çalıştır: `res://scenes/StereoViewScene.tscn`
3. `StereoViewScene` içinde `NetworkStreamUrl` değerini **laptop kaynak URL’i** olacak şekilde aynı Wi‑Fi ağında ayarla (örn. RTSP/HTTP).
4. Android plugin tarafında `QuestExternalTexture` singleton'ı aktif olmalı.

## Not

- Quest3 hedefi için bu yapı VR’ye uygun 3D sahne temeli sağlar.
- Bu projede **yalnızca external texture** hedeflenir; Android singleton yoksa görüntü gelmez.
