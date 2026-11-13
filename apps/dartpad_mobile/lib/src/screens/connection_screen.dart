import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';

/// Automatic & Manual Pairing Screen for `dartpad_mobile`.
///
/// Prioritizes **Automatic Discovery & Auto-Pairing** over both **Wi-Fi LAN**
/// and **USB Tethering (RNDIS / Hotspot)**, and automatically saves the paired
/// PC credentials to persistent storage so they survive device shutdowns.
class ConnectionScreen extends StatefulWidget {
  final MobileControllerEngine engine;
  final VoidCallback onBackToController;

  const ConnectionScreen({
    super.key,
    required this.engine,
    required this.onBackToController,
  });

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late final TextEditingController _qrUriController;
  late final TextEditingController _ipController;
  late final TextEditingController _portController;
  late final TextEditingController _pinController;

  bool _isAutoScanning = false;
  bool _isConnectingManual = false;
  String? _statusMessage;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    final s = widget.engine.settings;
    _qrUriController = TextEditingController();
    _ipController =
        TextEditingController(text: s.lastConnectedIp ?? '192.168.1.10');
    _portController = TextEditingController(
      text: s.lastConnectedPort.toString(),
    );
    _pinController = TextEditingController(text: s.lastPairedPin ?? '');

    // Automatically trigger Wi-Fi + USB discovery scan when opening screen if not yet connected
    if (!widget.engine.isConnected) {
      _runAutoDiscoverAndPair();
    }
  }

  @override
  void dispose() {
    _qrUriController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _runAutoDiscoverAndPair() async {
    if (_isAutoScanning) return;
    setState(() {
      _isAutoScanning = true;
      _isError = false;
      _statusMessage =
          'Mencari & Auto-Pairing PC via Wi-Fi LAN & USB Tethering...';
    });

    final ok = await widget.engine.discoverAndAutoConnect(
      timeout: const Duration(milliseconds: 1600),
    );
    if (!mounted) return;

    setState(() {
      _isAutoScanning = false;
      if (ok) {
        _isError = false;
        _statusMessage =
            'Berhasil Auto-Pair ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp})! Tersimpan otomatis.';
        _ipController.text = widget.engine.connectedServerIp ?? '';
        _pinController.text = widget.engine.settings.lastPairedPin ?? '';
      } else {
        _isError = true;
        _statusMessage =
            'PC belum terdeteksi otomatis. Pastikan DartPad.exe berjalan di PC (Wi-Fi satu jaringan atau aktifkan USB Tethering).';
      }
    });

    if (ok) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      if (mounted) widget.onBackToController();
    }
  }

  Future<void> _connectWithQrUri() async {
    setState(() {
      _isConnectingManual = true;
      _isError = false;
      _statusMessage = null;
    });
    try {
      final ok = await widget.engine.connectFromQrUri(_qrUriController.text);
      if (!mounted) return;
      if (ok) {
        widget.onBackToController();
      } else {
        setState(() {
          _isError = true;
          _statusMessage = 'Gagal terhubung via QR URI.';
        });
      }
    } on FormatException catch (e) {
      setState(() {
        _isError = true;
        _statusMessage = e.message;
      });
    } finally {
      if (mounted) setState(() => _isConnectingManual = false);
    }
  }

  Future<void> _connectManual() async {
    setState(() {
      _isConnectingManual = true;
      _isError = false;
      _statusMessage = null;
    });
    try {
      final port = int.tryParse(_portController.text.trim()) ??
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
        widget.onBackToController();
      } else {
        setState(() {
          _isError = true;
          _statusMessage =
              'Gagal terhubung: Periksa IP dan 6-digit PIN di layar PC.';
        });
      }
    } on FormatException catch (e) {
      setState(() {
        _isError = true;
        _statusMessage = e.message;
      });
    } finally {
      if (mounted) setState(() => _isConnectingManual = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.engine.settings;
    final theme = settings.themePreset;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          // Pressing Android Back on Connection screen returns to Controller instead of exiting APK!
          widget.onBackToController();
        }
      },
      child: Scaffold(
        backgroundColor: Color(theme.bgHex),
        appBar: AppBar(
          backgroundColor: Color(theme.panelHex),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Kembali ke Controller',
            onPressed: widget.onBackToController,
          ),
          title: const Text(
            'Auto-Pairing (Wi-Fi & USB) & Koneksi PC',
            style: TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          actions: [
            TextButton.icon(
              onPressed: widget.onBackToController,
              icon: Icon(Icons.sports_esports, color: Color(theme.accentHex)),
              label: Text(
                'Kembali ke Controller',
                style: TextStyle(
                    color: Color(theme.accentHex), fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Primary Automatic Wi-Fi & USB Pairing Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Color(theme.panelHex),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: Color(theme.accentHex).withValues(alpha: 0.6),
                      width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bolt, color: Color(theme.accentHex)),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Otomatisasi Pairing (Wi-Fi LAN & USB Tethering)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (settings.lastConnectedIp != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Tersimpan: ${settings.lastPairedServerName ?? "PC"} (${settings.lastConnectedIp})',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Tidak perlu ketik IP/PIN manual! Cukup jalankan DartPad.exe di PC (via Wi-Fi atau colok kabel USB + nyalakan USB Tethering). Koneksi otomatis disimpan walaupun HP/PC dimatikan.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _statusMessage!,
                        style: TextStyle(
                          color: _isError
                              ? Colors.amberAccent
                              : const Color(0xFF00E676),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Color(theme.accentHex),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed:
                            _isAutoScanning ? null : _runAutoDiscoverAndPair,
                        icon: _isAutoScanning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.black),
                              )
                            : const Icon(Icons.radar),
                        label: Text(
                          _isAutoScanning
                              ? 'Sedang Mencari PC di Wi-Fi & USB...'
                              : 'SCAN & AUTO-PAIR SEKARANG (Wi-Fi / USB)',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 2. Fallback Manual IP / PIN & QR URI Row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Color(theme.panelHex),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Opsi Cadangan: QR URI',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _qrUriController,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText:
                                  'dartpad://connect?ip=192.168.1.10&port=42100&pin=...',
                              hintStyle: TextStyle(color: Colors.white38),
                              filled: true,
                              fillColor: Color(0xFF0E131B),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isConnectingManual
                                  ? null
                                  : _connectWithQrUri,
                              icon: const Icon(Icons.qr_code, size: 16),
                              label: const Text('Connect via QR URI'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Color(theme.panelHex),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Opsi Cadangan: Input IP & PIN Manual',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: _ipController,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'IP PC (Wi-Fi / USB)',
                                    labelStyle: TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _portController,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'Port',
                                    labelStyle: TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _pinController,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    labelText: 'PIN 6-Digit',
                                    labelStyle: TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed:
                                  _isConnectingManual ? null : _connectManual,
                              child: Text(_isConnectingManual
                                  ? 'Menghubungkan...'
                                  : 'Connect Manual & Simpan'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
