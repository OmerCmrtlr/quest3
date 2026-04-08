# ZORUNLU: GStreamer Binary Dosyaları

Bu klasörde sadece `ReceiverDisplay.gd` bulunur.

`GStreamerReceiver` / `GStreamerCamera` node'larının gerçekten çalışması için,
çalışan bir Godot projesinden `addons/gstreamer/` klasörünü **tamamıyla** kopyalaman gerekir.

## Kopyalanması gerekenler

- `.gdextension` dosyaları
- Linux için `.so` dosyaları
- Android (tablet/Quest) için `arm64-v8a` altındaki `.so` dosyaları
- İlgili config/resource dosyaları

Android için pratik kontrol listesi:
- `addons/gstreamer/gstreamer.gdextension` içinde `android.debug.arm64` ve `android.release.arm64` map'i olmalı.
- `addons/gstreamer/bin/` altında bu map'lerin işaret ettiği `.so` dosyaları fiziksel olarak bulunmalı.
- Sadece `libgstreamer_godot.linux.*.so` varsa tablette receiver çalışmaz.

Eksik kopyada Godot editörde node tipi görünmez veya runtime'da yüklenmez.

## Bu projede ne görürsün?

- Ekranda `AĞ BACKEND YOK: GStreamer binary addon eksik` yazıyorsa sorun port/IP değil, binary addon eksikliğidir.
- Bu durumda uygulama network stream'i decode edemez.
