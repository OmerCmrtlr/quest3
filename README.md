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
  - Öncelik: Android singleton external texture (`QuestExternalTexture.get_camera_texture()`)
  - Fallback: yok (external texture zorunlu)
  - Stereo UV shift/zoom ayarları shader ile uygulanır.

- Yardımcı script: `scripts/external/CameraExternalTextureSender.cs`
  - Artık SHM/UDP sender değildir.
  - External texture singleton kaynağını test eden yardımcı node’dur.

## Bu Akışta Neler Yok?

- UDP sender/receiver zorunluluğu yok.
- GStreamer receiver zorunluluğu yok.
- Ortada çizgi/debug yazısı gibi 2D overlay yok.

## Hızlı Başlangıç

1. Projeyi Godot’ta aç.
2. `Project Settings -> Camera Feed -> Enable = ON`
3. Ana sahneyi çalıştır: `res://scenes/StereoViewScene.tscn`
4. Android’de Java plugin kullanacaksan singleton adı `QuestExternalTexture` ile `get_camera_texture()` dönüşü `Texture2D` olacak şekilde bağla.

## Not

- Quest3 hedefi için bu yapı VR’ye uygun 3D sahne temeli sağlar.
- Bu projede **yalnızca external texture** hedeflenir; Android singleton yoksa görüntü gelmez.
