import 'dart:async';
import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen Live Camera QR Code Scanner powered by `mobile_scanner`.
///
/// Uses `autoStart: true` (`DetectionSpeed.noDuplicates`) and avoids stopping the
/// camera during `AppLifecycleState.inactive` (such as OS permission dialogs)
/// to eliminate CameraX `genericError` startup races on Android.
class QrScannerScreen extends StatefulWidget {
  final MobileControllerEngine engine;

  const QrScannerScreen({
    super.key,
    required this.engine,
  });

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  MobileScannerController? _scannerController;
  int _cameraEpoch = 0;
  bool _pausedByLifecycle = false;

  bool _isConnecting = false;
  bool _torchOn = false;
  String? _statusHint;
  String? _errorText;
  String? _lastScannedRaw;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createController();
  }

  void _createController() {
    _scannerController?.dispose();
    final ctrl = MobileScannerController(
      autoStart: true,
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      formats: const [BarcodeFormat.qrCode],
    );
    _scannerController = ctrl;
    _pausedByLifecycle = false;
    _cameraEpoch++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _scannerController;
    if (ctrl == null) return;
    if (state == AppLifecycleState.paused) {
      _pausedByLifecycle = true;
      unawaited(ctrl.stop().catchError((_) {}));
    } else if (state == AppLifecycleState.resumed && _pausedByLifecycle) {
      _pausedByLifecycle = false;
      unawaited(ctrl.start().catchError((_) {}));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ctrl = _scannerController;
    _scannerController = null;
    if (ctrl != null) {
      unawaited(ctrl.stop().catchError((_) {}).whenComplete(ctrl.dispose));
    }
    super.dispose();
  }

  Future<void> _restartCamera() async {
    setState(() {
      _errorText = null;
      _statusHint = null;
      _lastScannedRaw = null;
      _torchOn = false;
      _createController();
    });
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
      _statusHint = 'QR terbaca! Menyambungkan ke PC...';
    });

    try {
      bool ok = false;
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        final uri = Uri.tryParse(trimmed);
        final pin = uri?.queryParameters['pin']?.trim() ?? '';
        if (uri != null && uri.host.isNotEmpty && pin.isNotEmpty) {
          ok = await widget.engine.connectWithPayload(
            PairingPayload(
              ip: uri.host,
              port: DartPadProtocolConstants.defaultPort,
              httpPort: uri.port > 0 ? uri.port : 42101,
              pin: pin,
              deviceName: 'Windows PC',
            ),
            timeout: const Duration(seconds: 4),
          );
        } else {
          throw const FormatException('QR URL tidak berisi IP PC dan PIN.');
        }
      } else {
        ok = await widget.engine.connectFromQrUri(
          trimmed,
          timeout: const Duration(seconds: 4),
        );
      }
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _isConnecting = false;
        _statusHint = null;
        _errorText = widget.engine.lastConnectionError ??
            'Gagal terhubung ke PC dari QR Code ini.';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _statusHint = null;
        _errorText = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _statusHint = null;
        _errorText = 'Kesalahan koneksi: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.engine.settings.themePreset;
    final ctrl = _scannerController;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      appBar: AppBar(
        backgroundColor: Color(theme.panelHex),
        elevation: 0,
        title: const Text(
          'Scan QR DartPad PC',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Muat Ulang Kamera',
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: _restartCamera,
          ),
          IconButton(
            tooltip: 'Flash',
            icon: Icon(
              _torchOn ? Icons.flash_on : Icons.flash_off,
              color: _torchOn ? Colors.amberAccent : Colors.white70,
            ),
            onPressed: ctrl == null
                ? null
                : () async {
                    try {
                      await ctrl.toggleTorch();
                      if (mounted) setState(() => _torchOn = !_torchOn);
                    } catch (_) {}
                  },
          ),
          IconButton(
            tooltip: 'Putar Kamera',
            icon: const Icon(Icons.cameraswitch, color: Colors.white70),
            onPressed: ctrl == null
                ? null
                : () {
                    unawaited(ctrl.switchCamera().catchError((_) {}));
                  },
          ),
        ],
      ),
      body: Stack(
        children: [
          if (ctrl != null)
            MobileScanner(
              key: ValueKey(_cameraEpoch),
              controller: ctrl,
              onDetect: (capture) {
                for (final barcode in capture.barcodes) {
                  final val = barcode.rawValue;
                  if (val != null &&
                      (val.trim().startsWith('dartpad://') ||
                          val.trim().contains('/pad?'))) {
                    _handleRawQr(val);
                    break;
                  }
                }
              },
              errorBuilder: (context, error, child) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.videocam_off_outlined,
                          color: Colors.white54,
                          size: 40,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Kamera belum siap (${error.errorCode.name}).\nPastikan izin Kamera aktif, lalu tap Muat Ulang.\n\nAlternatif cepat: buka http://<IP_PC>:42101/pad di Google Chrome HP.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: _restartCamera,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Muat Ulang Kamera'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

          // Minimalist Reticle Frame
          Center(
            child: Container(
              width: 230,
              height: 230,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _isConnecting
                      ? Colors.amberAccent
                      : Colors.white.withValues(alpha: 0.7),
                  width: 1.8,
                ),
              ),
            ),
          ),

          // Bottom Minimalist Diagnostic Sheet
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF16181D).withValues(alpha: 0.94),
                border: const Border(top: BorderSide(color: Color(0xFF252830))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isConnecting) ...[
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(theme.accentHex),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _statusHint ?? 'Menghubungkan ke PC...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ] else if (_errorText != null) ...[
                    Text(
                      _errorText!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFBBF24),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _restartCamera,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Muat Ulang & Scan Lagi'),
                    ),
                  ] else ...[
                    const Text(
                      'Arahkan kamera ke QR Code di jendela DartPad PC.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 12),
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
