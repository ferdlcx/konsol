import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ota_update/ota_update.dart';

import 'qr_scanner_screen.dart';

/// Minimalist Mobile Studio Dashboard Screen for `dartpad_mobile`.
///
/// Provides:
/// - **QR Camera Scanner** (lifecycle-safe Google ML Kit / `mobile_scanner`)
/// - **Auto-Discovery & PIN Matcher** (Wi-Fi LAN & USB Tethering)
/// - **Live Gamepad Console** (Minimalist Xbox & PlayStation layouts with L3/R3)
/// - **In-App OTA Updater** (`ota_update` downloads latest APK and installs in-place)
class DashboardScreen extends StatefulWidget {
  final MobileControllerEngine engine;
  final VoidCallback onOpenController;
  final VoidCallback onOpenSettings;
  final VoidCallback onSettingsChanged;

  const DashboardScreen({
    super.key,
    required this.engine,
    required this.onOpenController,
    required this.onOpenSettings,
    required this.onSettingsChanged,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TextEditingController _qrUriController = TextEditingController();
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController(
    text: DartPadProtocolConstants.defaultPort.toString(),
  );
  final TextEditingController _pinController = TextEditingController();

  List<LocalInterfaceInfo> _localIfaces = const [];
  List<DiscoveredReceiver> _discovered = const [];
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _showManualFallback = false;
  String? _statusMessage;
  bool _statusIsError = false;

  String? _latestVersionTag;
  String? _latestReleaseUrl;
  String? _latestApkUrl;
  bool _hasUpdateAvailable = false;
  bool _isUpdatingApk = false;
  int _otaProgress = 0;
  StreamSubscription<OtaEvent>? _otaSub;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    final s = widget.engine.settings;
    _ipController.text = s.lastConnectedIp ?? '192.168.1.10';
    _portController.text = s.lastConnectedPort.toString();
    _pinController.text = s.lastPairedPin ?? '';
    _discovered = widget.engine.discoveredReceivers;

    _refreshNetworkAndScan();
  }

  @override
  void dispose() {
    _otaSub?.cancel();
    _qrUriController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _setFeedback(String msg, {bool isError = false, bool showSnack = true}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusIsError = isError;
    });
    if (showSnack) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              isError ? const Color(0xFF7F1D1D) : const Color(0xFF1F242D),
          content: Text(msg, style: const TextStyle(color: Colors.white)),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _refreshNetworkAndScan() async {
    final ifaces = await MobileControllerEngine.detectLocalInterfaces();
    if (!mounted) return;
    setState(() {
      _localIfaces = ifaces;
      _isScanning = true;
    });

    final receivers = await widget.engine.discoverReceivers(
      timeout: const Duration(milliseconds: 1400),
      includeSubnetUnicastSweep: true,
    );
    if (!mounted) return;

    setState(() {
      _discovered = receivers;
      _isScanning = false;
    });

    if (receivers.isNotEmpty &&
        !widget.engine.isConnected &&
        widget.engine.settings.autoPairEnabled) {
      final first = receivers.first;
      if (first.pin != null && first.pin!.isNotEmpty) {
        await _connectToDiscovered(first, overridePin: first.pin!);
      }
    }
  }

  static const MethodChannel _googleQrChannel =
      MethodChannel('com.ferdlcx.dartpad/google_qr');

  Future<void> _openQrCameraScanner() async {
    // Primary: Google Play Services Code Scanner (zero CameraX genericError, auto-zoom!)
    if (Platform.isAndroid) {
      try {
        final raw = await _googleQrChannel.invokeMethod<String>('scanQr');
        if (!mounted) return;
        if (raw == null || raw.trim().isEmpty) {
          // User canceled Google scanner cleanly
          return;
        }
        await _connectFromScannedRaw(raw.trim());
        return;
      } on PlatformException {
        // Google Play Services scanner unavailable -> fall back to in-app camera scanner
      } on MissingPluginException {
        // Fallback to in-app camera scanner
      }
    }

    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrScannerScreen(engine: widget.engine),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      _setFeedback(
        'Terhubung ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp}) via Scan QR.',
      );
      setState(() {});
    }
  }

  Future<void> _connectFromScannedRaw(String trimmed) async {
    setState(() => _isConnecting = true);
    _setFeedback('QR terbaca! Menyambungkan ke PC...', showSnack: false);
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
      setState(() => _isConnecting = false);
      if (ok) {
        _ipController.text =
            widget.engine.connectedServerIp ?? _ipController.text;
        _pinController.text =
            widget.engine.settings.lastPairedPin ?? _pinController.text;
        _setFeedback(
          'Terhubung ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp}) via Google QR!',
        );
      } else {
        _setFeedback(
          widget.engine.lastConnectionError ??
              'Gagal terhubung ke PC dari QR Code ini.',
          isError: true,
        );
      }
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _setFeedback('Format QR tidak valid: ${e.message}', isError: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _setFeedback('Kesalahan koneksi QR: $e', isError: true);
    }
  }

  Future<void> _connectToDiscovered(
    DiscoveredReceiver rx, {
    required String overridePin,
  }) async {
    setState(() => _isConnecting = true);
    _setFeedback(
      'Menghubungkan ke ${rx.serverName} (${rx.ip}:${rx.udpPort})...',
      isError: false,
      showSnack: false,
    );

    final ok = await widget.engine.connectWithPayload(
      rx.toPayload(overridePin: overridePin),
      timeout: const Duration(seconds: 3),
    );

    if (!mounted) return;
    setState(() => _isConnecting = false);

    if (ok) {
      _ipController.text = rx.ip;
      _pinController.text = overridePin;
      _setFeedback(
        'Terhubung ke ${widget.engine.connectedServerName} (${rx.ip}).',
      );
    } else {
      _setFeedback(
        widget.engine.lastConnectionError ??
            'Gagal menyambungkan ke ${rx.ip}:${rx.udpPort}.',
        isError: true,
      );
    }
  }

  Future<void> _promptPinMatch(DiscoveredReceiver rx) async {
    final ctrl = TextEditingController(text: rx.pin ?? '');
    final enteredPin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(widget.engine.settings.themePreset.panelHex),
        title: Text('PIN ${rx.serverName}',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('IP PC: ${rx.ip}:${rx.udpPort}',
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Masukkan PIN 6-Digit',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Batal'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Hubungkan'),
          ),
        ],
      ),
    );
    if (enteredPin != null && enteredPin.isNotEmpty) {
      await _connectToDiscovered(rx, overridePin: enteredPin);
    }
  }

  Future<void> _connectWithQrUri() async {
    final uriText = _qrUriController.text.trim();
    if (uriText.isEmpty) {
      _setFeedback('Tempelkan teks QR URI terlebih dahulu.', isError: true);
      return;
    }

    setState(() => _isConnecting = true);
    _setFeedback('Membaca QR URI...', showSnack: false);

    try {
      final ok = await widget.engine.connectFromQrUri(
        uriText,
        timeout: const Duration(seconds: 4),
      );
      if (!mounted) return;
      setState(() => _isConnecting = false);
      if (ok) {
        _setFeedback(
          'Terhubung ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp}).',
        );
      } else {
        _setFeedback(
          widget.engine.lastConnectionError ??
              'Gagal terhubung via QR URI. Cek DartPad.exe & jaringan Wi-Fi/USB.',
          isError: true,
        );
      }
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _setFeedback(e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _setFeedback('Error koneksi QR URI: $e', isError: true);
    }
  }

  Future<void> _connectManual() async {
    final ip = _ipController.text.trim();
    final pin = _pinController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ??
        DartPadProtocolConstants.defaultPort;

    if (ip.isEmpty || pin.isEmpty) {
      _setFeedback('Isi IP PC dan PIN 6-Digit.', isError: true);
      return;
    }

    setState(() => _isConnecting = true);
    _setFeedback('Menghubungkan ke $ip:$port...', showSnack: false);

    try {
      final ok = await widget.engine.connectWithPayload(
        PairingPayload(
          ip: ip,
          port: port,
          pin: pin,
          deviceName: 'Windows PC',
        ),
        timeout: const Duration(seconds: 4),
      );
      if (!mounted) return;
      setState(() => _isConnecting = false);
      if (ok) {
        _setFeedback(
          'Terhubung ke ${widget.engine.connectedServerName} ($ip).',
        );
      } else {
        _setFeedback(
          widget.engine.lastConnectionError ?? 'Tidak ada respon dari $ip:$port.',
          isError: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isConnecting = false);
      _setFeedback('Error koneksi manual: $e', isError: true);
    }
  }

  Future<void> _checkLatestRelease() async {
    _setFeedback('Mengecek rilis terbaru di GitHub...', showSnack: false);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse(DartPadAppSettings.latestReleaseApiUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'DartPad-Android');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        _setFeedback(
          'Gagal cek update (HTTP ${resp.statusCode}).',
          isError: true,
        );
        return;
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name']?.toString() ?? 'v${DartPadAppSettings.appVersion}';
      final htmlUrl =
          json['html_url']?.toString() ?? DartPadAppSettings.releaseUrl;

      String? apkUrl;
      final assets = (json['assets'] as List<dynamic>?) ?? const [];
      for (final asset in assets) {
        if (asset is Map<String, dynamic> &&
            (asset['name']?.toString().endsWith('.apk') ?? false)) {
          apkUrl = asset['browser_download_url']?.toString();
          break;
        }
      }

      final normalizedTag = tag.startsWith('v') ? tag.substring(1) : tag;
      final updateFound = normalizedTag != DartPadAppSettings.appVersion &&
          apkUrl != null;

      if (!mounted) return;
      setState(() {
        _latestVersionTag = tag;
        _latestReleaseUrl = htmlUrl;
        _latestApkUrl = apkUrl;
        _hasUpdateAvailable = updateFound;
      });

      if (updateFound) {
        _setFeedback(
          'Update tersedia: $tag. Tekan "Install Update In-App" untuk memperbarui langsung.',
        );
      } else {
        _setFeedback(
          'Aplikasi sudah versi terbaru (v${DartPadAppSettings.appVersion}).',
        );
      }
    } catch (e) {
      _setFeedback('Gagal mengecek update: $e', isError: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _startInAppOtaUpdate() async {
    final apkUrl = _latestApkUrl;
    if (apkUrl == null || _isUpdatingApk) return;

    setState(() {
      _isUpdatingApk = true;
      _otaProgress = 0;
    });
    _setFeedback('Mengunduh APK $_latestVersionTag...', showSnack: false);

    try {
      await _otaSub?.cancel();
      _otaSub = OtaUpdate()
          .execute(
            apkUrl,
            destinationFilename: 'dartpad-mobile-update.apk',
          )
          .listen(
            (event) {
              if (!mounted) return;
              switch (event.status) {
                case OtaStatus.DOWNLOADING:
                  setState(() {
                    _otaProgress = int.tryParse(event.value ?? '0') ?? 0;
                  });
                  break;
                case OtaStatus.INSTALLING:
                  setState(() {
                    _otaProgress = 100;
                    _isUpdatingApk = false;
                  });
                  _setFeedback('Membuka installer Android untuk menimpa versi lama...');
                  break;
                case OtaStatus.DOWNLOAD_ERROR:
                case OtaStatus.INTERNAL_ERROR:
                case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
                case OtaStatus.CHECKSUM_ERROR:
                case OtaStatus.INSTALLATION_ERROR:
                  setState(() => _isUpdatingApk = false);
                  _setFeedback(
                    'Update terhenti (${event.status.name}): ${event.value ?? "Izinkan Install unknown apps di Pengaturan"}.',
                    isError: true,
                  );
                  break;
                default:
                  break;
              }
            },
            onError: (e) {
              if (!mounted) return;
              setState(() => _isUpdatingApk = false);
              _setFeedback('Error OTA Update: $e', isError: true);
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isUpdatingApk = false);
      _setFeedback('Gagal memulai OTA Update: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.engine.settings;
    final theme = settings.themePreset;
    final connected = widget.engine.isConnected;
    final profile = widget.engine.profile;
    const hairline = Color(0xFF252830);
    const emerald = Color(0xFF22C55E);

    return Scaffold(
      backgroundColor: Color(theme.bgHex),
      appBar: AppBar(
        backgroundColor: Color(theme.panelHex),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: hairline),
        ),
        title: Row(
          children: [
            const Text(
              'DartPad',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 17,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Color(theme.bgHex),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: hairline),
              ),
              child: const Text(
                'v${DartPadAppSettings.appVersion}',
                style: TextStyle(color: Colors.white60, fontSize: 10),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Pengaturan',
            icon: const Icon(Icons.tune, color: Colors.white70, size: 20),
            onPressed: widget.onOpenSettings,
          ),
          IconButton(
            tooltip: 'Keluar APK',
            icon: const Icon(Icons.power_settings_new,
                color: Colors.white54, size: 20),
            onPressed: () {
              widget.engine.releaseAllInputs();
              SystemNavigator.pop();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshNetworkAndScan,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            // 1. Connection Status Card (Minimalist Studio Hairline)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: connected
                      ? emerald.withValues(alpha: 0.45)
                      : hairline,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: connected ? emerald : Colors.white24,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connected
                                  ? (widget.engine.connectedServerName ??
                                      'Windows PC')
                                  : 'Siap Disambungkan',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              connected
                                  ? 'Terhubung (${widget.engine.transportMode}) • ${widget.engine.connectedServerIp} • ${widget.engine.lastRttMs.toStringAsFixed(0)} ms'
                                  : 'Scan QR di jendela DartPad PC atau sambung otomatis Wi-Fi/USB.',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (connected)
                        TextButton(
                          onPressed: () async {
                            await widget.engine.disconnect(stopAutoPair: true);
                            _setFeedback('Koneksi diputuskan.');
                          },
                          child: const Text('Putus',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ),
                    ],
                  ),
                  if (_localIfaces.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final iface in _localIfaces)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Color(theme.bgHex),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: hairline),
                            ),
                            child: Text(
                              '${iface.kind}: ${iface.ip}',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _statusIsError
                            ? const Color(0xFF2B1717)
                            : Color(theme.bgHex),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _statusIsError
                              ? const Color(0xFF7F1D1D)
                              : hairline,
                        ),
                      ),
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                          color: _statusIsError
                              ? const Color(0xFFFCA5A5)
                              : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 2. Primary Action Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Color(theme.panelHex),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: hairline),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _isConnecting ? null : _openQrCameraScanner,
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    label: const Text(
                      'Scan QR',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(theme.accentHex),
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: widget.onOpenController,
                    icon: const Icon(Icons.sports_esports, size: 20),
                    label: const Text(
                      'Buka Konsol',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 3. Discovered PCs
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Deteksi PC (Wi-Fi & USB)',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _isScanning ? null : _refreshNetworkAndScan,
                        icon: _isScanning
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh,
                                size: 16, color: Colors.white70),
                        label: Text(
                          _isScanning ? 'Mencari...' : 'Scan Ulang',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  if (_discovered.isEmpty)
                    const Text(
                      'Belum ada PC terdeteksi. Pastikan DartPad.exe aktif di Windows pada Wi-Fi atau USB Tether yang sama.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    )
                  else
                    for (final rx in _discovered)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Color(theme.bgHex),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: hairline),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    rx.serverName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    '${rx.ip}:${rx.udpPort} • ${rx.transportHint}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: hairline),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10),
                              ),
                              onPressed: _isConnecting
                                  ? null
                                  : () => _promptPinMatch(rx),
                              child: const Text('PIN',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                            ),
                            const SizedBox(width: 6),
                            if (rx.pin != null && rx.pin!.isNotEmpty)
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Color(theme.accentHex),
                                  foregroundColor: Colors.black,
                                  elevation: 0,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                ),
                                onPressed: _isConnecting
                                    ? null
                                    : () => _connectToDiscovered(
                                          rx,
                                          overridePin: rx.pin!,
                                        ),
                                child: const Text('Pair',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 4. Quick Config & In-App OTA Update
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Konfigurasi & Update Aplikasi',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('Tampilan Kontroler:',
                          style:
                              TextStyle(color: Colors.white60, fontSize: 12)),
                      const Spacer(),
                      SegmentedButton<ControllerType>(
                        segments: const [
                          ButtonSegment(
                            value: ControllerType.xbox,
                            label: Text('Xbox', style: TextStyle(fontSize: 11)),
                          ),
                          ButtonSegment(
                            value: ControllerType.playstation,
                            label: Text('PS (△○□✕)',
                                style: TextStyle(fontSize: 11)),
                          ),
                        ],
                        selected: {profile.type},
                        onSelectionChanged: (sel) {
                          final nextType = sel.first;
                          widget.engine.setProfile(
                            ControllerProfile(
                              id: nextType == ControllerType.xbox
                                  ? 'xbox_default'
                                  : 'ps_default',
                              name: nextType == ControllerType.xbox
                                  ? 'Xbox Default'
                                  : 'PlayStation Default',
                              type: nextType,
                              deadzone: profile.deadzone,
                              sensitivity: profile.sensitivity,
                              enableVolumeKeysAsTriggers:
                                  profile.enableVolumeKeysAsTriggers,
                              hardwareKeyBindings: profile.hardwareKeyBindings,
                              buttonLabels: {
                                for (final b in GamepadButton.values)
                                  b: nextType.labelFor(b),
                              },
                            ),
                          );
                          widget.onSettingsChanged();
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Text('Skala Tombol:',
                          style:
                              TextStyle(color: Colors.white60, fontSize: 12)),
                      Expanded(
                        child: Slider(
                          value: settings.globalScale.clamp(0.6, 1.5).toDouble(),
                          min: 0.6,
                          max: 1.5,
                          activeColor: Color(theme.accentHex),
                          onChanged: (v) {
                            widget.engine.updateSettings(
                              settings.copyWith(globalScale: v),
                            );
                            widget.onSettingsChanged();
                            setState(() {});
                          },
                        ),
                      ),
                      Text('${(settings.globalScale * 100).round()}%',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ],
                  ),
                  if (_isUpdatingApk) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _otaProgress > 0 ? _otaProgress / 100.0 : null,
                      backgroundColor: Color(theme.bgHex),
                      color: Color(theme.accentHex),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Mengunduh pembaruan: $_otaProgress%',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: hairline),
                          ),
                          onPressed: widget.onOpenSettings,
                          icon: const Icon(Icons.tune, size: 15),
                          label: const Text('Tema & Info',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: _hasUpdateAvailable
                                  ? emerald.withValues(alpha: 0.6)
                                  : hairline,
                            ),
                          ),
                          onPressed: _isUpdatingApk
                              ? null
                              : (_hasUpdateAvailable
                                  ? _startInAppOtaUpdate
                                  : _checkLatestRelease),
                          icon: const Icon(Icons.system_update_alt, size: 15),
                          label: Text(
                            _hasUpdateAvailable
                                ? 'Install $_latestVersionTag'
                                : (_latestVersionTag != null
                                    ? 'Rilis $_latestVersionTag'
                                    : 'Cek Update'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_latestReleaseUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(
                        _latestReleaseUrl!,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 5. Manual Connection Fallback & Browser Controller Alternative
            Container(
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: hairline),
              ),
              child: ExpansionTile(
                initiallyExpanded: _showManualFallback,
                onExpansionChanged: (v) =>
                    setState(() => _showManualFallback = v),
                title: const Text(
                  'Koneksi Manual (Paste URI / IP & PIN)',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                children: [
                  TextField(
                    controller: _qrUriController,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'Tempel QR URI (dartpad://connect?...)',
                      labelStyle:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                      filled: true,
                      fillColor: Color(theme.bgHex),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isConnecting ? null : _connectWithQrUri,
                      icon: _isConnecting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link, size: 16),
                      label: Text(_isConnecting
                          ? 'Menyambungkan...'
                          : 'Hubungkan via QR URI'),
                    ),
                  ),
                  const Divider(color: hairline, height: 22),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _ipController,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'IP PC',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _pinController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'PIN',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_quickCandidateIps().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final ip in _quickCandidateIps())
                          ActionChip(
                            label: Text(
                              ip,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                            ),
                            backgroundColor: Color(theme.bgHex),
                            side: const BorderSide(color: hairline),
                            onPressed: () {
                              setState(() {
                                _ipController.text = ip;
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _isConnecting ? null : _connectManual,
                      child: const Text('Hubungkan Manual (IP + PIN)'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Color(theme.bgHex),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: hairline),
                    ),
                    child: SelectableText(
                      'Alternatif Tanpa Kamera / Tanpa APK:\nBuka http://${_ipController.text.trim().isNotEmpty ? _ipController.text.trim() : "<IP_PC>"}:42101/pad di Google Chrome HP atau scan tab "QR Browser (/pad)" di PC.',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _quickCandidateIps() {
    final ips = <String>{};
    final saved = widget.engine.settings.lastConnectedIp;
    if (saved != null && saved.isNotEmpty) ips.add(saved);
    for (final iface in _localIfaces) {
      final p = iface.ip.split('.');
      if (p.length == 4) {
        ips.add('${p[0]}.${p[1]}.${p[2]}.1');
      }
    }
    ips.addAll(const ['192.168.42.129', '192.168.137.1', '127.0.0.1']);
    return ips.toList();
  }
}
