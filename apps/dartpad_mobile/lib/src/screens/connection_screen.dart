import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';

/// Home & Connection Screen for `dartpad_mobile`.
///
/// Allows the user to:
/// 1. Paste / Scan the `dartpad://connect?...` QR Code URI displayed on the Windows PC.
/// 2. Or enter the PC's Local IP, Port (`42100`), and 6-digit Pairing PIN manually.
/// 3. Configure physical Volume Up / Volume Down trigger bindings (`LT`/`RT`) and deadzone.
class ConnectionScreen extends StatefulWidget {
  final MobileControllerEngine engine;
  final VoidCallback onConnected;

  const ConnectionScreen({
    super.key,
    required this.engine,
    required this.onConnected,
  });

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final TextEditingController _qrUriController = TextEditingController();
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.1.10');
  final TextEditingController _portController = TextEditingController(
    text: DartPadProtocolConstants.defaultPort.toString(),
  );
  final TextEditingController _pinController = TextEditingController();

  bool _isConnecting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _qrUriController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _connectWithQrUri() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });
    try {
      final ok = await widget.engine.connectFromQrUri(_qrUriController.text);
      if (!mounted) return;
      if (ok) {
        widget.onConnected();
      } else {
        setState(() => _errorMessage = 'Gagal terhubung: PIN ditolak atau PC tidak merespon.');
      }
    } on FormatException catch (e) {
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _connectManual() async {
    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });
    try {
      final port =
          int.tryParse(_portController.text.trim()) ??
          DartPadProtocolConstants.defaultPort;
      final payload = PairingPayload(
        ip: _ipController.text.trim(),
        port: port,
        pin: _pinController.text.trim(),
        deviceName: 'Windows PC',
      );
      final ok = await widget.engine.connectWithPayload(payload);
      if (!mounted) return;
      if (ok) {
        widget.onConnected();
      } else {
        setState(() => _errorMessage = 'Gagal terhubung: Periksa IP dan 6-digit PIN di layar PC.');
      }
    } on FormatException catch (e) {
      setState(() => _errorMessage = e.message);
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.engine.profile;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121722),
        title: const Text(
          'DartPad Mobile Controller',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton.icon(
            onPressed: widget.onConnected,
            icon: const Icon(Icons.sports_esports, color: Color(0xFF00E5FF)),
            label: const Text(
              'Buka Controller / Edit Layout',
              style: TextStyle(color: Color(0xFF00E5FF)),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left Column: QR Code Pairing
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF151B26),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.qr_code_scanner, color: Color(0xFF00E5FF)),
                        SizedBox(width: 8),
                        Text(
                          'Scan / Paste QR Code dari PC',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Jalankan dartpad_receiver.exe di Windows PC, lalu scan QR Code yang tampil di layar PC.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _qrUriController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: 'dartpad://connect?ip=192.168.1.10&port=42100&pin=...',
                        hintStyle: TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Color(0xFF0E131B),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: _isConnecting ? null : _connectWithQrUri,
                        icon: const Icon(Icons.qr_code),
                        label: const Text(
                          'Connect via QR Payload',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 20),

            // Right Column: Manual IP + 6-Digit PIN & Volume Trigger Settings
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF151B26),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Koneksi Manual (Wi-Fi / USB Tethering)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _ipController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'IP Address PC',
                              labelStyle: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _portController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'Port UDP',
                              labelStyle: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _pinController,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '6-Digit Pairing PIN (lihat di PC)',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Tombol Volume HP sebagai Trigger (LT / RT)',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      subtitle: const Text(
                        'Volume Up = LT/L2 • Volume Down = RT/R2',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      value: profile.enableVolumeKeysAsTriggers,
                      activeColor: const Color(0xFF00E5FF),
                      onChanged: (val) {
                        widget.engine.setProfile(
                          ControllerProfile(
                            id: profile.id,
                            name: profile.name,
                            type: profile.type,
                            deadzone: profile.deadzone,
                            sensitivity: profile.sensitivity,
                            buttonLabels: profile.buttonLabels,
                            enableVolumeKeysAsTriggers: val,
                            hardwareKeyBindings: profile.hardwareKeyBindings,
                          ),
                        );
                        setState(() {});
                      },
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isConnecting ? null : _connectManual,
                        child: Text(
                          _isConnecting ? 'Menghubungkan...' : 'Connect dengan PIN',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
