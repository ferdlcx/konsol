# DartPad — Customizable Low-Latency Android Gamepad for Windows PC

**DartPad** mengubah smartphone Android menjadi virtual gamepad **Xbox 360** atau **PlayStation (DualShock 4)** untuk Windows 10/11 melalui **Wi-Fi** maupun **USB Tethering**, dengan latensi sangat rendah (`120 Hz` + *Instant Edge-Triggered Dispatch `0 ms`*).

---

## Fitur Utama

1. **QR Code & 6-Digit PIN Pairing**:
   - Aplikasi Windows Receiver (`dartpad_receiver.exe`) otomatis menampilkan **QR Code** dan **PIN 6-digit** di layar PC.
   - Aplikasi Android (`dartpad_mobile`) cukup scan QR Code atau memasukkan PIN untuk terhubung secara aman di jaringan lokal.
2. **Ultra-Low Latency (`0 ms` Edge-Trigger + `120 Hz` State Sync)**:
   - Setiap sentuhan tombol langsung dikirim detik itu juga tanpa menunggu tick timer berikutnya.
   - Menggunakan *Zero-Allocation Buffer Reuse* (28-byte binary UDP packet) agar bebas dari *Garbage Collection (GC) lag*.
   - *Out-of-Order Packet Drop* & *Watchdog Auto-Release (`200 ms`)* memastikan tidak ada tombol yang nyangkut saat sinyal terputus.
3. **Tombol Fisik Volume HP sebagai Trigger (`LT` / `RT`)**:
   - Menekan **Volume Up** (`LT` / `L2`) dan **Volume Down** (`RT` / `R2`) langsung menembakkan analog trigger `100%` tanpa memunculkan pop-up volume Android.
4. **Interactive Layout Editor & Tombol Combo**:
   - Geser posisi tombol/analog (`x`, `y`), ubah ukuran gede/kecil (`scale 50%–250%`), dan atur transparansi (`opacity`).
   - Buat **Tombol Combo** kustom (mis. `LB + RB + Y` dalam 1 tombol) yang menekan beberapa tombol sekaligus.
5. **Dual Haptic & Force Feedback (Getar)**:
   - Getaran ringan saat tombol/volume trigger ditekan di layar HP.
   - **PC Game Force Feedback (`RUMBLE`)**: Getaran motor besar/kecil (`LargeMotor` & `SmallMotor`) dari game PC dikirim balik via UDP ke HP Android secara real-time.
6. **Live Controller Button Tester di EXE**:
   - Verifikasi langsung apakah semua tombol, analog stick, volume trigger, dan tombol combo merespon di Windows Receiver (`--self-test` maupun tampilan live monitor).

---

## Struktur Monorepo

```text
konsol/
├── packages/
│   └── dartpad_protocol/     # Shared binary codec (28-byte), QR payload, Layout/Combo/Profile, Low-Latency Engine
├── apps/
│   ├── dartpad_receiver/     # Windows PC Receiver CLI/EXE, QR Renderer, Watchdog, Live Button Tester, FFI
│   └── dartpad_mobile/       # Android Flutter App (Controller Screen, CustomPainter 360° Joystick, Layout Editor)
└── native/
    └── dartpad_vgamepad/     # C/C++ DLL bridge (ViGEmClient Xbox 360 / DS4 + Rumble Callback)
```

---

## Cara Menjalankan & Menguji

### 1. Jalankan Seluruh Automated Tests & EXE Button Self-Test
```bash
dart pub get
dart test packages/dartpad_protocol apps/dartpad_receiver
dart run apps/dartpad_receiver/bin/dartpad_receiver.dart --self-test
```

### 2. Compile Windows Receiver ke `.exe`
```bash
dart compile exe apps/dartpad_receiver/bin/dartpad_receiver.dart -o dartpad_receiver.exe
./dartpad_receiver.exe
```

### 3. Build Native Windows Virtual Gamepad DLL (`dartpad_vgamepad.dll`)
```bash
cmake -S native/dartpad_vgamepad -B build/native -DUSE_VIGEM=ON
cmake --build build/native --config Release
```
Letakkan `dartpad_vgamepad.dll` di folder yang sama dengan `dartpad_receiver.exe`. Jika driver belum terinstal, `dartpad_receiver.exe` otomatis berjalan dalam mode **Live Button Tester / Simulation** sehingga Anda tetap bisa mengetes respon semua tombol dari HP.