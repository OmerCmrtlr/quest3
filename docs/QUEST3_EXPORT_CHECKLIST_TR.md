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
- Camera Feed -> Enable = ON
- Stereo sahne 3D mesh + SubViewport yapısında çalışıyor olmalı

## 3) Export Preset (Android)

- `Project -> Export -> Add... -> Android`
- Package name ayarla (`com.bnfnc.quest3` gibi gerçek bir unique name)
- Export path doldur (`build/android/Quest3-tablet-debug.apk`)
- `Gradle Build = ON` (C# `net8.0` projesinde template tarafı `net9.0` uyarısını pratikte aşmak için)
- Permissions:
  - CAMERA
- XR/OpenXR ihtiyacına göre ilgili ayarları aç

> Not: Export ekranında `net8.0 -> net9.0 template` uyarısı görürsen iki seçenek var:
> 1) **Önerilen (bu projede ayarlandı):** Gradle Build ON ile export almak.
> 2) Projeyi `net9.0` hedefleyip .NET 9 SDK kurmak.

## 4) Build Öncesi Test

- `StereoViewScene` açıldığında görüntü 3D mesh üstünde geliyor mu?
- Ortada çizgi / debug overlay / split 2D UI olmadığını doğrula.
- `EyeTextureShiftPixels` ve `EyeTextureZoom` ayarları beklendiği gibi çalışıyor mu?

## 5) Build ve Kurulum

- Export APK
- `adb install -r <apk_adi>.apk`
- Quest içinde uygulamayı çalıştır

## 6) Sorun Giderme

- Siyah ekran: kamera izni reddedilmiş olabilir; Android ayarlarından izin ver.
- Kamera gelmiyor: uygun `CameraIndex` seçilmemiş olabilir.
- Java singleton kullanılacaksa:
  - singleton adı `QuestExternalTexture`
  - metod adı `get_camera_texture()`
  - `Texture2D` döndürdüğünü doğrula.
