import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'qr_scanner_screen.dart';

/// Main Mobile Dashboard Screen for `dartpad_mobile`.
///
/// Opens first when the app launches (instead of jumping straight into raw controls).
/// Provides:
/// - **Camera QR Code Scanner** (Google ML Kit / `mobile_scanner`) as the #1 pairing method
/// - **Automatic PC Discovery (Wi-Fi LAN & USB Tethering)** + **PIN Matching**
/// - **Own Device IP Detection** (shows HP Wi-Fi & USB Tethering IPs automatically)
/// - **Manual QR URI / IP+PIN Fallback** with immediate inline & SnackBar diagnostics
/// - **One-Tap Launch Gamepad Console** (works both connected & offline)
/// - **Quick Settings (Theme, Besar-Kecil, Preset Xbox/PS, Update Check & Release Info)**
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

  @override
  void initState() {
    super.initState();
    // Restore comfortable portrait/auto orientation on the Mobile Dashboard
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
              isError ? const Color(0xFFB71C1C) : const Color(0xFF1B5E20),
          content: Text(msg, style: const TextStyle(color: Colors.white)),
          duration: const Duration(seconds: 4),
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

  Future<void> _openQrCameraScanner() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrScannerScreen(engine: widget.engine),
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      _setFeedback(
        'Terhubung ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp}) via Scan QR!',
      );
      setState(() {});
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
        'Berhasil terhubung ke ${widget.engine.connectedServerName} (${rx.ip})! Tersimpan permanen.',
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
        title: Text('Cocokkan PIN untuk ${rx.serverName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('IP PC terdeteksi otomatis: ${rx.ip}:${rx.udpPort}',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Masukkan PIN 6-Digit dari layar PC',
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
    _setFeedback('Membaca QR URI & menghubungi PC...', showSnack: false);

    try {
      final ok = await widget.engine.connectFromQrUri(
        uriText,
        timeout: const Duration(seconds: 4),
      );
      if (!mounted) return;
      setState(() => _isConnecting = false);
      if (ok) {
        _setFeedback(
          'Terhubung ke ${widget.engine.connectedServerName} (${widget.engine.connectedServerIp})!',
        );
      } else {
        _setFeedback(
          widget.engine.lastConnectionError ??
              'Gagal terhubung via QR URI. Cek apakah DartPad.exe berjalan & HP/PC satu jaringan.',
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
      _setFeedback('Isi IP PC dan PIN 6-Digit terlebih dahulu.', isError: true);
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
          'Terhubung ke ${widget.engine.connectedServerName} ($ip)! Tersimpan otomatis.',
        );
      } else {
        _setFeedback(
          widget.engine.lastConnectionError ??
              'Tidak ada respon dari $ip:$port.',
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
      final tag = json['tag_name']?.toString() ?? 'v0.2.0';
      final htmlUrl =
          json['html_url']?.toString() ?? DartPadAppSettings.releaseUrl;
      if (!mounted) return;
      setState(() {
        _latestVersionTag = tag;
        _latestReleaseUrl = htmlUrl;
      });
      await Clipboard.setData(ClipboardData(text: htmlUrl));
      _setFeedback(
        'Versi terbaru di GitHub: $tag (Terpasang: v${DartPadAppSettings.appVersion}). Link rilis sudah disalin ke clipboard!',
      );
    } catch (e) {
      _setFeedback('Tidak dapat terhubung ke GitHub: $e', isError: true);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.engine.settings;
    final theme = settings.themePreset;
    final connected = widget.engine.isConnected;
    final profile = widget.engine.profile;

    return Scaffold(
      backgroundColor: Color(theme.bgHex),
      appBar: AppBar(
        backgroundColor: Color(theme.panelHex),
        title: Row(
          children: [
            Icon(Icons.sports_esports, color: Color(theme.accentHex)),
            const SizedBox(width: 8),
            const Text(
              'DartPad Dashboard',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 17,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Color(theme.primaryHex).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'v${DartPadAppSettings.appVersion}',
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings, Theme & Besar-Kecil',
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: widget.onOpenSettings,
          ),
          IconButton(
            tooltip: 'Keluar APK',
            icon: const Icon(Icons.power_settings_new, color: Colors.redAccent),
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
            // 1. Hero Connection Status & Automatic Own-IP Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: connected
                      ? const Color(0xFF00E676)
                      : Color(theme.accentHex).withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        connected ? Icons.check_circle : Icons.wifi_find,
                        color: connected
                            ? const Color(0xFF00E676)
                            : Color(theme.accentHex),
                        size: 26,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              connected
                                  ? 'TERHUBUNG KE ${widget.engine.connectedServerName ?? "PC"}'
                                  : 'BELUM TERHUBUNG KE PC',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              connected
                                  ? 'IP PC: ${widget.engine.connectedServerIp} • Latency ${widget.engine.lastRttMs.toStringAsFixed(0)} ms'
                                  : 'Gunakan Scan QR Kamera (Tercepat) atau Scan Otomatis Wi-Fi & USB.',
                              style: const TextStyle(
                                color: Colors.white70,
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
                              style: TextStyle(color: Colors.redAccent)),
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
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Text(
                              'HP ${iface.kind}: ${iface.ip}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _statusIsError
                            ? Colors.red.withValues(alpha: 0.16)
                            : Colors.green.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _statusIsError
                              ? Colors.redAccent
                              : const Color(0xFF00E676),
                        ),
                      ),
                      child: Text(
                        _statusMessage!,
                        style: TextStyle(
                          color: _statusIsError
                              ? Colors.amberAccent
                              : const Color(0xFF69F0AE),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 2. Primary Action Buttons: SCAN QR CAMERA & OPEN GAMEPAD CONSOLE
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(theme.accentHex),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _isConnecting ? null : _openQrCameraScanner,
                    icon: const Icon(Icons.qr_code_scanner, size: 24),
                    label: const Text(
                      'SCAN QR KAMERA',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(theme.primaryHex),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: widget.onOpenController,
                    icon: const Icon(Icons.gamepad, size: 24),
                    label: const Text(
                      'BUKA KONSOL',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 3. Auto-Discovered PCs (Wi-Fi LAN + USB Tethering) & PIN Matcher
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.radar, color: Color(theme.accentHex), size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Deteksi PC Otomatis (Wi-Fi LAN & USB)',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _isScanning ? null : _refreshNetworkAndScan,
                        icon: _isScanning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: Text(_isScanning ? 'Scanning...' : 'Scan Ulang'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_discovered.isEmpty)
                    const Text(
                      'Belum ada PC terdeteksi di jaringan. Pastikan DartPad.exe terbuka di Windows, satu Wi-Fi/Router dengan PC (atau USB Tethering aktif), lalu tekan Scan Ulang atau Scan QR Kamera.',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    )
                  else
                    for (final rx in _discovered)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Color(theme.accentHex).withValues(alpha: 0.4),
                          ),
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
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    '${rx.ip}:${rx.udpPort} • ${rx.transportHint}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton(
                              onPressed: _isConnecting
                                  ? null
                                  : () => _promptPinMatch(rx),
                              child: const Text('PIN',
                                  style: TextStyle(fontSize: 11)),
                            ),
                            const SizedBox(width: 6),
                            if (rx.pin != null && rx.pin!.isNotEmpty)
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Color(theme.accentHex),
                                  foregroundColor: Colors.black,
                                ),
                                onPressed: _isConnecting
                                    ? null
                                    : () => _connectToDiscovered(
                                          rx,
                                          overridePin: rx.pin!,
                                        ),
                                child: const Text('Pair',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 4. Quick Controls: Preset, Global Size, Theme & Update Check
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Konfigurasi Cepat & Pembaruan',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Mode Kontroler:',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const Spacer(),
                      SegmentedButton<ControllerType>(
                        segments: const [
                          ButtonSegment(
                            value: ControllerType.xbox,
                            label: Text('Xbox Big', style: TextStyle(fontSize: 11)),
                          ),
                          ButtonSegment(
                            value: ControllerType.playstation,
                            label: Text('PlayStation', style: TextStyle(fontSize: 11)),
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
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Ukuran Tombol:',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
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
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onOpenSettings,
                          icon: const Icon(Icons.palette, size: 16),
                          label: const Text('Theme & Info Rilis'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _checkLatestRelease,
                          icon: const Icon(Icons.system_update, size: 16),
                          label: Text(_latestVersionTag != null
                              ? 'Terbaru: $_latestVersionTag'
                              : 'Cek Update'),
                        ),
                      ),
                    ],
                  ),
                  if (_latestReleaseUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(
                        'Link Update: $_latestReleaseUrl',
                        style: TextStyle(
                          color: Color(theme.accentHex),
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 5. Expandable Manual Paste QR URI & Manual IP+PIN Fallback
            Container(
              decoration: BoxDecoration(
                color: Color(theme.panelHex),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: ExpansionTile(
                initiallyExpanded: _showManualFallback,
                onExpansionChanged: (v) =>
                    setState(() => _showManualFallback = v),
                title: const Text(
                  'Koneksi Manual (Paste QR URI / Ketik IP & PIN)',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                children: [
                  TextField(
                    controller: _qrUriController,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: const InputDecoration(
                      labelText: 'Tempel QR URI (dartpad://connect?...)',
                      labelStyle: TextStyle(color: Colors.white70, fontSize: 12),
                      filled: true,
                      fillColor: Color(0xFF0B0E14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isConnecting ? null : _connectWithQrUri,
                      icon: _isConnecting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(_isConnecting
                          ? 'Menyambungkan...'
                          : 'Hubungkan via Paste QR URI'),
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 22),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _ipController,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
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
                          style: const TextStyle(color: Colors.white, fontSize: 12),
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
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'PIN',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _isConnecting ? null : _connectManual,
                      child: const Text('Hubungkan Manual (IP + PIN)'),
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
}
