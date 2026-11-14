# DartPad — Customizable Low-Latency Android Gamepad for Windows PC

**DartPad** mengubah smartphone Android menjadi virtual gamepad **Xbox 360** atau **PlayStation (DualShock 4)** untuk Windows 10/11 melalui **Wi-Fi** maupun **USB Tethering**, dengan latensi sangat rendah (`120 Hz` + *Instant Edge-Triggered Dispatch `0 ms`*).

## 📥 Download Rilis Terbaru (`v0.2.0`) — Super Praktis!

* **Halaman GitHub Release**: [https://github.com/ferdlcx/konsol/releases/tag/v0.2.0](https://github.com/ferdlcx/konsol/releases/tag/v0.2.0)
* **💿 Windows PC Setup Installer (Otomatis Pasang Shortcut, Firewall Rule UDP `42100` & TCP `42101`, dan Auto-Start — Bisa Langsung Timpa Versi Lama)**:
  [Download `DartPad-Setup.exe`](https://github.com/ferdlcx/konsol/releases/download/v0.2.0/DartPad-Setup.exe)
* **💻 Windows PC Portable Single Launcher (1 File `.exe` Langsung Jalan Tanpa Install)**:
  [Download `DartPad.exe`](https://github.com/ferdlcx/konsol/releases/download/v0.2.0/DartPad.exe)
* **📱 Android Mobile Controller (`.apk` — Mobile Dashboard, Camera QR Scanner Google ML Kit, Auto-Pair Subnet LAN+USB, Kontrol 2x Besar & Keystore Tetap untuk Timpa Update)**:
  [Download `dartpad-mobile-android.apk`](https://github.com/ferdlcx/konsol/releases/download/v0.2.0/dartpad-mobile-android.apk)

> **Catatan Update & Keamanan OS**:
> * Mulai **`v0.2.0`** ke depan, seluruh `.apk` ditandatangani dengan keystore tetap sehingga versi berikutnya dapat langsung **ditimpa** tanpa menghapus data/layout tersimpan (khusus upgrade dari `v0.1.0` awal ke `v0.2.0` disarankan uninstall `v0.1.0` sekali saja karena masih memakai debug key).
> * Untuk Windows (`DartPad-Setup.exe` / `DartPad.exe`), jika muncul **Windows SmartScreen**, klik **More info → Run anyway** (build open-source komunitas belum memakai sertifikat berbayar EV). Di Dashboard PC juga tersedia tombol **🛡️ Izinkan Firewall & Fix USB Tether LAN**.

---

## Fitur Utama

1. **Mobile Dashboard Awal + Camera QR Scanner (`dartpad_mobile`)**:
   - Saat APK dibuka, pengguna masuk ke **Mobile Dashboard** terlebih dahulu (bukan langsung ke tombol konsol).
   - **Scan QR Code Kamera (Google ML Kit)** diprioritaskan di paling atas, lengkap dengan preview IP HP & daftar PC yang terdeteksi otomatis (**Wi-Fi** maupun **USB Tethering**), pencocokan **PIN 6-Digit**, tombol **BUKA KONSOL**, serta cek update rilis.
2. **Auto-Pair Lintas Wi-Fi HP ↔ LAN PC & USB Tethering Android 12–15**:
   - Mengatasi router/AP yang memblokir UDP broadcast dengan menyapu subnet `/24` unicast UDP + HTTP `/api/info` (`port 42101`), memprioritaskan IP fisik (LAN/Wi-Fi/USB RNDIS) di atas adapter virtual (WSL/Hyper-V), serta menaikkan **Interface Metric USB RNDIS = 500** di Windows agar internet kabel LAN PC tidak terganggu saat USB Tethering aktif.
3. **1 File Launcher Tunggal di Windows (`DartPad.exe` — 100% Pure Dart + GUI Dashboard)**:
   - Tanpa `.dll` C++ tambahan: cukup jalankan **`DartPad.exe`**, dan **GUI Dashboard Dark Gaming** langsung tampil berisi **QR Code Grafis (SVG)** multi-IP, **PIN 6-digit permanen**, **Semua IP PC Aktif**, tombol **"🛡️ Izinkan Firewall & Fix USB Tether LAN"**, serta **Live Visual Gamepad Tester**.
4. **Layout Bawaan Mirip Xbox Asli (Analog Kiri, XYAB & Bumper ~2x Lebih Besar + Anti-Nabrak)**:
   - Layout bawaan `xbox_authentic_v2` memperbesar **Left Stick (`LS`)**, tombol **`Y / X / B / A`**, serta **`LT / LB / RB / RT`** agar jauh lebih nyaman di jempol, teruji **0% overlap** pada viewport landscape Android.
5. **Tombol `DASHBOARD` & `CLOSE` di Tengah Atas + Combo Urutan (`ms`)**:
   - Bar tengah atas konsol menyediakan tombol kembali ke **Dashboard**, **Settings/Theme**, **`EDIT / COMBO`**, dan **`CLOSE`**.
   - Tersedia combo bawaan **`(1)` (`X → Y → A → A`, 75 ms)** dan **`(2)` (`LB + RB`)** plus combo builder kustom.
6. **Tombol Fisik Volume HP sebagai Trigger (`LT` / `RT`) & Dual Force Feedback (Getar)**:
   - Menekan **Volume Up** (`LT`) dan **Volume Down** (`RT`) langsung mengirim trigger 100% disertai Haptic & Game Force Feedback.

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