# Quest3 / Tablet - 3D External Texture Kurulum Rehberi

Bu proje artık **UDP/GStreamer akışına bağlı değildir**. Amaç:

- 2D UI olmadan,
- iki `SubViewport` ile stereo üretip,
- görüntüyü 3D mesh üzerinde göstermek,
- default ekranda tam ekran tek göz çıktısı vermektir.

## Dosya Mimarisi

- `scenes/StereoViewScene.tscn` -> ana 3D stereo sahne
- `scripts/stereo/Stereo3DViewer.cs` -> external texture + stereo mesh kontrolü
- `scenes/ExternalTextureScene.tscn` -> external texture kaynağı test sahnesi
- `scripts/external/CameraExternalTextureSender.cs` -> external texture source provider

## Sahne Akışı

`StereoViewScene` içinde:

- `LeftEyeViewport` ve `RightEyeViewport` aynı noktada çalışır.
- Her viewport içinde bir kamera + bir video mesh vardır.
- Tek kamera kaynağı iki viewport’a da basılır.
- Ana ekrana (`MainDisplayMesh`) varsayılan olarak sol göz tam ekran verilir.

## Godot Ayarları

- `Project Settings -> Camera Feed -> Enable = ON`
- Main Scene: `res://scenes/StereoViewScene.tscn`

## External Texture Kaynağı (Android)

Bir Android singleton sağlanabiliyorsa script şu metodu arar:

- Singleton adı: `QuestExternalTexture`
- Metod: `get_camera_texture()`
- Beklenen dönüş: `Texture2D`

Bu projede `EnableLocalCameraFallback=false` kullanıldığı için singleton yoksa görüntü siyah kalır.
Bu nedenle Java tarafındaki `QuestExternalTexture` singleton implementasyonu zorunludur.

## Hızlı Test

1. `StereoViewScene` çalıştır.
2. Görüntü geliyorsa 3D mesh akışı hazırdır.
3. Gerekirse inspector’dan:
   - `EyeTextureShiftPixels`
   - `EyeTextureZoom`
   - `CenterOffsetPixels`
   ayarlarını yap.

## Not

Eski `python/stereo_webcam_gst_sender.py` dosyası repoda kalsa da bu yeni akışta gerekli değildir.
