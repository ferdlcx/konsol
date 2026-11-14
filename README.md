# DartPad — Customizable Low-Latency Android Gamepad for Windows PC

**DartPad** mengubah smartphone Android menjadi virtual gamepad **Xbox 360** atau **PlayStation (DualShock 4)** untuk Windows 10/11 melalui **Wi-Fi** maupun **USB Tethering**, dengan latensi sangat rendah (`120 Hz` + *Instant Edge-Triggered Dispatch `0 ms`*).

## 📥 Download Rilis Terbaru (`v0.3.2`) — Dual Pairing (UDP + TCP WebSocket) & Web Controller

* **Halaman GitHub Release**: [https://github.com/ferdlcx/konsol/releases/tag/v0.3.2](https://github.com/ferdlcx/konsol/releases/tag/v0.3.2)
* **💿 Windows PC Setup Installer (PALING DIREKOMENDASIKAN — Otomatis Pasang Driver ViGEmBus, `ViGEmClient.dll`, Shortcut, & Firewall Rule UDP `42100` / TCP `42101`)**:
  [Download `DartPad-Setup.exe`](https://github.com/ferdlcx/konsol/releases/download/v0.3.2/DartPad-Setup.exe)
* **💻 Windows PC Portable Single Launcher (`1 File .exe` Tanpa Blink CMD + 1-Klik Pemasang ViGEmBus di Dashboard)**:
  [Download `DartPad.exe`](https://github.com/ferdlcx/konsol/releases/download/v0.3.2/DartPad.exe)
* **📱 Android Mobile Controller (`.apk` — Pairing Hybrid UDP + TCP WebSocket Anti "No Response", Kamera QR Fix, & Update In-App OTA)**:
  [Download `dartpad-mobile-android.apk`](https://github.com/ferdlcx/konsol/releases/download/v0.3.2/dartpad-mobile-android.apk)
* **🌐 Metode Alternatif Tanpa Install APK (Browser Touch Gamepad)**:
  Buka **`http://<IP_PC>:42101/pad`** langsung dari Google Chrome HP (atau scan tab **QR Web Controller** di Dashboard PC dengan Google Lens / Kamera bawaan HP).

> **Catatan Penting Agar Game Membaca Controller & Keamanan OS**:
> * **Agar Game PC Mendeteksi Stik Xbox 360 / PS4**: Game Windows membaca perangkat XInput/DualShock melalui driver kernel **ViGEmBus** (`ViGEmBus` + `ViGEmClient.dll`). Gunakan **`DartPad-Setup.exe`** agar driver otomatis terpasang, atau jika memakai portable **`DartPad.exe`**, klik tombol **"⬇️ Pasang Driver Virtual Gamepad (ViGEmBus)"** satu kali di Dashboard PC.
> * **Pilih Mode Xbox 360 / Sony PS4 di PC**: Di Dashboard Windows `v0.3.0`, Anda bisa mengganti identitas virtual controller antara **Xbox 360 (XInput)** dan **Sony DualShock 4** kapan saja sesuai game yang dimainkan.
> * **Timpa Update & SmartScreen / Android Sideload**: Mulai `v0.2.0+`, `.apk` dan Windows Setup memakai keystore & `AppId` tetap sehingga versi baru bisa **langsung ditimpa** atau di-update langsung lewat tombol **Update In-App** di dalam aplikasi. Untuk Windows SmartScreen (build open-source belum memiliki sertifikat berbayar EV), klik **More info → Run anyway**; di Android cukup izinkan sumber instalasi satu kali saat diminta OS.

---

## Fitur Utama (`v0.3.0`)

1. **Driver Virtual Gamepad Asli untuk Game PC (`ViGEmClient.dll` + `ViGEmBus` — Xbox 360 & Sony DualShock 4)**:
   - Mengirim laporan hardware asli `XUSB` (Xbox 360) dan `DS4` (Sony DualShock 4) via FFI langsung dari Dart ke `ViGEmClient.dll` beserta polling **Force Feedback / Rumble** dari game ke getar HP Android.
2. **Bebas Kedip CMD (`Zero Blink`) & Anti Putus Mendadak**:
   - Jendela CMD otomatis disembunyikan setelah GUI terbuka (`SW_HIDE`) agar tidak mengganggu atau tertutup tak sengaja di tengah main game. Dilengkapi **Single-Instance Guard** dan tombol eksplisit **"Matikan DartPad"** di Dashboard GUI.
3. **Minimalist Studio UI + Tombol `L3` / `R3` & Simbol PlayStation (`△`, `○`, `□`, `✕`)**:
   - Desain matte obsidian tanpa warna mencolok, penambahan tombol **`L3`** & **`R3`** khusus anti-nabrak (`0% overlap`), serta painter vektor asli **`△` / `○` / `□` / `✕`** saat memakai mode/preset PlayStation.
4. **Camera QR Scanner Anti-Error (`genericError` Fix) + Auto-Pair LAN / USB Tethering**:
   - Kontroler kamera lifecycle-safe (`autoStart: false`, `WidgetsBindingObserver`, `Retry` bersih) agar kamera langsung siap memindai QR setelah izin diberikan, plus Auto-Discovery subnet `/24` & USB RNDIS Metric `500`.
5. **Haptic & Rumble Nyata (`vibration`) + In-App Updater (`ota_update` & Windows Updater)**:
   - Sentuhan tombol dan efek getar game memakai motor vibrasi Android langsung, dan cek/pasang pembaruan rilis baru tersedia langsung dari Dashboard HP maupun PC.

---

## Cara Menjalankan & Compile dari Source Code

### 1. Jalankan Seluruh Automated Tests & Self-Test
```bash
dart pub get
dart test packages/dartpad_protocol apps/dartpad_receiver
dart run apps/dartpad_receiver/bin/dartpad_receiver.dart --self-test
```

### 2. Compile Windows Single Launcher (`DartPad.exe`)
```bash
dart compile exe apps/dartpad_receiver/bin/dartpad_receiver.dart -o DartPad.exe
./DartPad.exe
```