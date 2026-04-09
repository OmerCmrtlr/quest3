# Quest3 APK Export Checklist

## 1) Android Export Hazırlık

- Godot Android export template kurulu
- Keystore hazır (debug/release)
- Android SDK/JDK path Godot'ta tanımlı

Bu çalışma ortamında doğrulanan değerler:
- Java SDK Path: `/usr/lib/jvm/java-17-openjdk-amd64`
- Android SDK Path: `/home/bnfnc/Android/Sdk`

## 2) Project Settings

- Main Scene -> `res://scenes/StereoViewScene.tscn`
- Stereo sahne 3D mesh + SubViewport yapısında çalışıyor olmalı
- `NetworkStreamUrl` aynı Wi‑Fi ağındaki kaynak URL ile ayarlı olmalı

## 3) Export Preset (Android)

- `Project -> Export -> Add... -> Android`
- Package name ayarla (`com.bnfnc.quest3` gibi gerçek bir unique name)
- Export path doldur (`build/android/Quest3-tablet-debug.apk`)
- `Gradle Build = ON` (C# `net8.0` projesinde template tarafı `net9.0` uyarısını pratikte aşmak için)
- Permissions:
  - INTERNET
  - ACCESS_NETWORK_STATE
  - ACCESS_WIFI_STATE
- XR/OpenXR ihtiyacına göre ilgili ayarları aç

> Not: Export ekranında `net8.0 -> net9.0 template` uyarısı görürsen iki seçenek var:
> 1) **Önerilen (bu projede ayarlandı):** Gradle Build ON ile export almak.
> 2) Projeyi `net9.0` hedefleyip .NET 9 SDK kurmak.

## 4) Build Öncesi Test

- Laptop sender çalışıyor mu?
  - `./tools/stream/start_rtsp_sender.sh`
  - `./tools/stream/status_rtsp_sender.sh`
  - Gerekirse manuel kamera: `./tools/stream/start_rtsp_sender.sh /dev/video1`
- `StereoViewScene` açıldığında görüntü 3D mesh üstünde geliyor mu?
- Ortada çizgi / debug overlay / split 2D UI olmadığını doğrula.
- `EyeTextureShiftPixels` ve `EyeTextureZoom` ayarları beklendiği gibi çalışıyor mu?

## 5) Build ve Kurulum

- Export APK
- `adb install -r <apk_adi>.apk`
- Quest içinde uygulamayı çalıştır

## 6) Sorun Giderme

- Siyah ekran: `NetworkStreamUrl` yanlış veya kaynağa erişim yok olabilir.
- Sender açılmıyorsa docker servis durumunu kontrol et (`systemctl status docker`).
- Laptop IP değiştiyse URL’i güncelle (örnek: `rtsp://192.168.2.207:8554/quest3`).
- Düşük çekim gücü gecikmeye sebep olur; mümkünse 5 GHz veya mobil hotspot ile kısa mesafe test et.
- Java singleton/plugin kullanılacaksa:
  - singleton adı `QuestExternalTexture`
  - `configure_external_texture` / `set_stream_url` / `start_stream` metodlarının erişilebilir olduğunu doğrula.
