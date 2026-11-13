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
   - Menampilkan **QR Code Grafis (SVG)**, **PIN 6-digit permanen** (tersimpan di `~/.dartpad/receiver_pin.txt`), **Live Visual Gamepad Tester** (semua tombol, analog, volume trigger, dan combo menyala *real-time*), serta tombol **"Test Getar (Rumble) ke HP"**.
2. **Layout Bawaan Mirip Xbox Asli, Responsif & Anti-Nabrak (`dartpad-mobile-android.apk`)**:
   - Tata letak asimetris **Xbox Series**: Analog Kiri (`LS`) di kiri-atas, Cross **D-Pad 8-arah** di kiri-bawah dalam, Diamond **`Y / X / B / A`** berwarna autentik Xbox di kanan-atas, Analog Kanan (`RS`) di kanan-bawah dalam, dan Bumper/Trigger (`LT/LB` & `RB/RT`) melengkung di bahu atas.
   - Ukuran seluruh elemen proporsional terhadap layar HP (`shortestSide`) dan dikunci agar tidak pernah bertabrakan atau keluar layar.
   - Setiap tombol memiliki *isolated touch state* sehingga 60–120 FPS tetap mulus tanpa lag UI.
3. **Tombol `CLOSE` di Tengah Atas & Navigasi Back Aman**:
   - Terdapat tombol **`CLOSE`** di bar tengah atas untuk keluar dari aplikasi dengan aman atau berpindah ke menu Pairing/Settings.
   - Menekan tombol Back Android saat berada di halaman Pairing akan kembali ke layar Controller (tidak langsung menutup APK).
4. **Tombol Combo Urutan Milidetik (`Sequence ms`) & Instan (`Simultaneous`)**:
   - Sudah tersedia tombol **`(1)`** bawaan berisi urutan **`X → Y → A → A`** (`75 ms` per langkah) dan **`(2)`** (`LB + RB` serentak).
   - Anda bisa menambah tombol Combo baru dengan mode **Urutan Milidetik (Macro)** (bisa mengulang tombol yang sama seperti `X, Y, A, A` dengan slider jeda `20 ms – 500 ms`) maupun **Serentak Instan**.
5. **Pairing Otomatis (Wi-Fi & USB Tethering) + Auto-Save Permanen**:
   - Memprioritaskan **Auto-Pair & Auto-Reconnect** otomatis di latar belakang melalui **USB Tethering (RNDIS)** maupun **Wi-Fi LAN** tanpa perlu ketik IP/PIN manual.
   - Seluruh data PC yang sudah di-pair, layout kustom, tombol combo, ukuran tombol (**Besar-Kecil Global Scale**), dan **Theme** (Xbox Carbon Green, Cyberpunk Neon Cyan, PlayStation Astro Blue, Crimson Elite Red) tersimpan permanen di memori internal dan **tidak hilang walaupun HP atau PC dimatikan/restart**.
6. **Tombol Fisik Volume HP sebagai Trigger (`LT` / `RT`) & Dual Force Feedback (Getar)**:
   - Menekan **Volume Up** (`LT` / `L2`) dan **Volume Down** (`RT` / `R2`) langsung menembakkan analog trigger `100%` + getar Haptic & PC Force Feedback (`RUMBLE`).

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