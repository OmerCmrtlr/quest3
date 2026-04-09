# Quest3 / Tablet - 3D External Texture Kurulum Rehberi

Bu proje yalnızca **network external texture** akışını kullanır. Amaç:

- 2D UI olmadan,
- iki `SubViewport` ile stereo üretip,
- görüntüyü 3D mesh üzerinde göstermek,
- default ekranda tam ekran tek göz çıktısı vermektir.

## Dosya Mimarisi

- `scenes/StereoViewScene.tscn` -> ana 3D stereo sahne
- `scripts/stereo/Stereo3DViewer.cs` -> external texture + stereo mesh kontrolü

## Sahne Akışı

`StereoViewScene` içinde:

- `LeftEyeViewport` ve `RightEyeViewport` aynı noktada çalışır.
- Her viewport içinde bir kamera + bir video mesh vardır.
- Tek kamera kaynağı iki viewport’a da basılır.
- Ana ekrana (`MainDisplayMesh`) varsayılan olarak sol göz tam ekran verilir.

## Godot Ayarları

- Main Scene: `res://scenes/StereoViewScene.tscn`

## External Texture Kaynağı (Android)

Java plugin singleton adı: `QuestExternalTexture`

Godot C# tarafı plugin ile şu çağrıları yapar:

- `configure_external_texture(texture_id, width, height)`
- `set_stream_url(url)`
- `start_stream()`

Bu projede fallback yoktur; singleton veya stream yoksa görüntü siyah kalır.

Not: Tablet cihazın yerel kamera erişimi bu akışta kullanılmaz.

## Hızlı Test

1. `StereoViewScene` çalıştır.
2. Inspector'dan `NetworkStreamUrl` değerini aynı Wi‑Fi ağındaki kaynak URL ile doldur.
3. Görüntü geliyorsa 3D mesh akışı hazırdır.
4. Gerekirse inspector’dan:
   - `EyeTextureShiftPixels`
   - `EyeTextureZoom`
   - `CenterOffsetPixels`
   ayarlarını yap.

## Not

Bu proje yalnızca laptop kaynaklı aynı Wi‑Fi network stream + external texture + 3D mesh gösterim hattını içerir.
