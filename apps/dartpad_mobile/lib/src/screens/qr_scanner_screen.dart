import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen Live Camera QR Code Scanner powered by Google ML Kit (`mobile_scanner`).
///
/// Prioritizes fast, one-shot scanning of the DartPad Windows Dashboard QR code
/// (`dartpad://connect?ip=...&ips=...&port=...&pin=...`) with real-time error
/// diagnostics and flashlight toggle.
class QrScannerScreen extends StatefulWidget {
  final MobileControllerEngine engine;

  const QrScannerScreen({
    super.key,
    required this.engine,
  });

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  bool _isConnecting = false;
  bool _torchOn = false;
  String? _errorText;
  String? _lastScannedRaw;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _handleRawQr(String raw) async {
    if (_isConnecting) return;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == _lastScannedRaw && _errorText != null) return;

    _lastScannedRaw = trimmed;
    setState(() {
      _isConnecting = true;
      _errorText = null;
    });

    try {
      final ok = await widget.engine.connectFromQrUri(
        trimmed,
        timeout: const Duration(seconds: 4),
      );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _isConnecting = false;
        _errorText = widget.engine.lastConnectionError ??
            'Gagal terhubung ke PC dari QR Code ini.';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _errorText = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _errorText = 'Kesalahan koneksi: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.engine.settings.themePreset;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Color(theme.panelHex),
        title: const Text(
          'Scan QR Code DartPad PC',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Lampu Flash',
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? Colors.amberAccent : Colors.white70,
            ),
            onPressed: () async {
              await _scannerController.toggleTorch();
              setState(() => _torchOn = !_torchOn);
            },
          ),
          IconButton(
            tooltip: 'Putar Kamera',
            icon: const Icon(Icons.cameraswitch, color: Colors.white70),
            onPressed: () => _scannerController.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final val = barcode.rawValue;
                if (val != null && val.trim().startsWith('dartpad://')) {
                  _handleRawQr(val);
                  break;
                }
              }
            },
            errorBuilder: (context, error, child) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Kamera tidak dapat dibuka (${error.errorCode.name}). Pastikan izin Kamera diberikan untuk DartPad di Pengaturan Android.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 14),
                  ),
                ),
              );
            },
          ),

          // Target Reticle Overlay
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _isConnecting
                      ? Colors.amberAccent
                      : Color(theme.accentHex),
                  width: 3,
                ),
              ),
            ),
          ),

          // Bottom Status & Diagnostic Overlay
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.84),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isConnecting) ...[
                    CircularProgressIndicator(color: Color(theme.accentHex)),
                    const SizedBox(height: 10),
                    const Text(
                      'QR Terbaca! Sedang menyambungkan ke PC...',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ] else if (_errorText != null) ...[
                    Text(
                      _errorText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _errorText = null;
                          _lastScannedRaw = null;
                        });
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Scan Ulang QR'),
                    ),
                  ] else ...[
                    const Text(
                      'Arahkan kamera ke QR Code di jendela DartPad PC.\nQR URI (dartpad://connect?...) langsung dikenali otomatis.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
