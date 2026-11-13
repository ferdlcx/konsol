# DartPad — Customizable Low-Latency Android Gamepad for Windows PC

**DartPad** mengubah smartphone Android menjadi virtual gamepad **Xbox 360** atau **PlayStation (DualShock 4)** untuk Windows 10/11 melalui **Wi-Fi** maupun **USB Tethering**, dengan latensi sangat rendah (`120 Hz` + *Instant Edge-Triggered Dispatch `0 ms`*).

## 📥 Download Rilis (`v0.1.0`) — Cukup 2 File!

* **Halaman GitHub Release**: [https://github.com/ferdlcx/konsol/releases/tag/v0.1.0](https://github.com/ferdlcx/konsol/releases/tag/v0.1.0)
* **💻 Windows PC Launcher + GUI Dashboard (1 File `.exe` Saja, Tanpa `.dll` / `.zip`)**:
  [Download `DartPad.exe`](https://github.com/ferdlcx/konsol/releases/download/v0.1.0/DartPad.exe)
* **📱 Android Mobile Controller (`.apk` — Bisa Edit Layout & Setting Tanpa Pair Dulu)**:
  [Download `dartpad-mobile-android.apk`](https://github.com/ferdlcx/konsol/releases/download/v0.1.0/dartpad-mobile-android.apk)

---

## Fitur Utama

1. **1 File Launcher Tunggal di Windows (`DartPad.exe` — 100% Pure Dart + GUI Dashboard)**:
   - Tidak perlu file `.dll` C++ terpisah atau ekstrak `.zip`. Cukup jalankan **`DartPad.exe`**, dan jendela **GUI Dashboard Dark Gaming** langsung terbuka otomatis!
   - Menampilkan **QR Code Grafis (SVG)**, **PIN 6-digit**, **Live Visual Gamepad Tester** (semua tombol, analog, volume trigger, dan combo menyala *real-time*), serta tombol **"Test Getar (Rumble) ke HP"**.
2. **Offline-First di Android (`dartpad-mobile-android.apk` — Tidak Wajib Pair untuk Setting)**:
   - Begitu aplikasi Android dibuka, Anda langsung berada di layar **Controller**.
   - Anda bebas mengatur **Settings** (Deadzone, Sensitivity, Preset Xbox/PS, Volume Trigger, Getar Haptic), menggeser & mengubah ukuran tombol di **Layout Editor**, serta membuat **Tombol Combo** secara **OFFLINE tanpa harus pairing ke PC terlebih dahulu**.
   - Tombol **`PAIR PC`** di bar atas hanya dipakai ketika Anda siap menyambungkan HP ke komputer.
3. **Ultra-Low Latency (`0 ms` Edge-Trigger + `120 Hz` State Sync)**:
   - Setiap sentuhan tombol langsung dikirim detik itu juga tanpa menunggu tick timer berikutnya.
   - Menggunakan *Zero-Allocation Buffer Reuse* (28-byte binary UDP packet) agar bebas dari *Garbage Collection (GC) lag*.
   - *Out-of-Order Packet Drop* & *Watchdog Auto-Release (`200 ms`)* memastikan tidak ada tombol yang nyangkut saat sinyal terputus.
4. **Tombol Fisik Volume HP sebagai Trigger (`LT` / `RT`)**:
   - Menekan **Volume Up** (`LT` / `L2`) dan **Volume Down** (`RT` / `R2`) langsung menembakkan analog trigger `100%` tanpa memunculkan pop-up volume Android.
5. **Dual Haptic & Force Feedback (Getar)**:
   - Getaran ringan saat tombol/volume trigger ditekan di layar HP.
   - **PC Game Force Feedback (`RUMBLE`)**: Getaran motor besar/kecil dari PC dikirim balik via UDP ke HP Android secara real-time.

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