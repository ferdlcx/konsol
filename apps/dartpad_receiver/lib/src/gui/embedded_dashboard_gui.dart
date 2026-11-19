import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartpad_protocol/dartpad_protocol.dart';

import '../diagnostics/qr_pairing_renderer.dart';
import '../network/receiver_server.dart';
import '../virtual_device/pure_dart_windows_provider.dart';

/// Embedded Desktop GUI Dashboard & HTTP Discovery API Server built directly into
/// `DartPad.exe`.
class EmbeddedDashboardGui {
  static const String officialVigemBusUrl =
      'https://github.com/nefarius/ViGEmBus/releases/download/v1.22.0/ViGEmBus_1.22.0_x64_x86_arm64.exe';
  static String get officialVigemClientAssetUrl =>
      'https://github.com/ferdlcx/konsol/releases/download/v${DartPadAppSettings.appVersion}/ViGEmClient.dll';
  static const String fallbackVigemClientAssetUrl =
      'https://github.com/ferdlcx/konsol/releases/latest/download/ViGEmClient.dll';

  final DartPadReceiverServer receiverServer;
  final String localIp;
  final List<String> allIps;
  final int preferredPort;
  final VoidCallback? onShutdownRequested;

  HttpServer? _httpServer;
  final Set<WebSocket> _clients = {};
  final Set<WebSocket> _controlClients = {};

  EmbeddedDashboardGui({
    required this.receiverServer,
    required this.localIp,
    this.allIps = const [],
    this.preferredPort = 42101,
    this.onShutdownRequested,
  });

  int get guiPort => _httpServer?.port ?? 0;
  String get dashboardUrl => 'http://127.0.0.1:$guiPort';

  List<String> get _resolvedIps {
    final ips = <String>[];
    if (localIp.isNotEmpty) ips.add(localIp);
    for (final ip in allIps) {
      if (ip.isNotEmpty && !ips.contains(ip)) ips.add(ip);
    }
    return ips;
  }

  /// Checks if an already-running DartPad instance is listening on [port].
  /// If found, asks it to reopen its GUI window and returns `true`.
  static Future<bool> tryActivateExistingInstance({int port = 42101}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 450);
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/api/open-ui'))
          .timeout(const Duration(milliseconds: 550));
      final resp = await req.close().timeout(const Duration(milliseconds: 550));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Starts the HTTP Discovery API + GUI server on `0.0.0.0:42101` (or ephemeral
  /// fallback) and optionally opens the native desktop window on Windows.
  Future<void> start({
    bool openDesktopWindow = true,
    bool bindLoopbackOnly = false,
  }) async {
    receiverServer.onRumbleGenerated = broadcastRumbleToControlClients;
    final bindAddr =
        bindLoopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4;
    try {
      _httpServer = await HttpServer.bind(bindAddr, preferredPort);
    } catch (_) {
      _httpServer = await HttpServer.bind(bindAddr, 0);
    }
    _httpServer!.listen(_handleRequest);

    if (openDesktopWindow && Platform.isWindows) {
      unawaited(fixWindowsFirewallAndUsbMetric(silent: true));
      _launchWindowsDesktopWindow(dashboardUrl);
    }
  }

  /// Broadcasts Force Feedback / Rumble events to any connected TCP WebSocket
  /// or Browser `/pad` controllers.
  void broadcastRumbleToControlClients(RumbleEvent rumble) {
    if (_controlClients.isEmpty) return;
    final payload = jsonEncode({
      'type': 'rumble',
      'large': rumble.largeMotor,
      'small': rumble.smallMotor,
      'durationMs': rumble.durationMs,
    });
    final stale = <WebSocket>[];
    for (final ws in _controlClients) {
      try {
        ws.add(payload);
      } catch (_) {
        stale.add(ws);
      }
    }
    _controlClients.removeAll(stale);
  }

  /// Broadcasts the latest [ReceiverDiagnosticsSnapshot] to all open GUI windows
  /// over WebSocket in real time (`< 1 ms` local loopback).
  void broadcastSnapshot(ReceiverDiagnosticsSnapshot snap) {
    if (_clients.isEmpty) return;
    final payload = jsonEncode(_snapshotToJson(snap));
    final disconnected = <WebSocket>[];
    for (final ws in _clients) {
      try {
        ws.add(payload);
      } catch (_) {
        disconnected.add(ws);
      }
    }
    _clients.removeAll(disconnected);
  }

  Future<void> stop() async {
    receiverServer.onRumbleGenerated = null;
    for (final ws in _controlClients) {
      await ws.close();
    }
    _controlClients.clear();
    for (final ws in _clients) {
      await ws.close();
    }
    _clients.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;

    if (req.method == 'OPTIONS') {
      req.response
        ..statusCode = HttpStatus.noContent
        ..headers.add('Access-Control-Allow-Origin', '*')
        ..headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        ..headers.add('Access-Control-Allow-Headers', 'Content-Type');
      await req.response.close();
      return;
    }

    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      _clients.add(ws);
      ws.done.then((_) => _clients.remove(ws));
      ws.add(
        jsonEncode(
          _snapshotToJson(
            ReceiverDiagnosticsSnapshot(
              isConnected: receiverServer.isClientConnected,
              currentState: receiverServer.currentState,
              packetsPerSecond: 0,
              packetLossPercent: 0.0,
              droppedOutOfOrder: 0,
              lastSequence: 0,
            ),
          ),
        ),
      );
      return;
    }

    // Bidirectional TCP WebSocket controller transport (reliable fallback when UDP replies are blocked
    // AND primary transport for the zero-install Mobile Browser Gamepad at /pad).
    if (path == '/ws-control' && WebSocketTransformer.isUpgradeRequest(req)) {
      final token = req.uri.queryParameters['token']?.trim();
      final pin = req.uri.queryParameters['pin']?.trim();
      final devName =
          req.uri.queryParameters['name']?.trim() ?? 'WebSocket Controller';
      final remoteIp = req.connectionInfo?.remoteAddress.address;

      var authorized = receiverServer.isValidSessionToken(token);
      if (!authorized && pin != null && pin == receiverServer.pairingPin) {
        final pairRes = receiverServer.handleHttpPair(
          pin: pin,
          deviceName: devName,
          clientAddress: remoteIp,
        );
        authorized = pairRes['ok'] == true;
      }

      if (!authorized) {
        req.response.statusCode = HttpStatus.unauthorized;
        await req.response.close();
        return;
      }

      final ws = await WebSocketTransformer.upgrade(req);
      _controlClients.add(ws);
      ws.add(
        jsonEncode({
          'type': 'ready',
          'serverName': receiverServer.serverName,
          'sessionToken': receiverServer.activeSessionToken,
          'deviceType': receiverServer.gamepadProvider.deviceType.name,
        }),
      );

      ws.listen(
        (dynamic message) {
          if (message is List<int>) {
            try {
              final bytes = Uint8List.fromList(message);
              final pkt = PacketCodec.decodeInput(bytes);
              receiverServer.handleExternalInputState(
                pkt.state,
                sequence: pkt.sequence,
                clientAddress: remoteIp,
                clientDeviceName: devName,
              );
            } catch (_) {
              // Ignore malformed binary frame
            }
            return;
          }
          if (message is String) {
            try {
              final data = jsonDecode(message) as Map<String, dynamic>;
              final msgType = data['type']?.toString();
              if (msgType == 'ping') {
                ws.add(jsonEncode({'type': 'pong', 'ts': data['ts']}));
                return;
              }
              if (msgType == 'disconnect') {
                receiverServer.handleHttpUnpair();
                return;
              }
              if (msgType == 'input') {
                final stateMap = data['state'];
                if (stateMap is Map<String, dynamic>) {
                  final st = ControllerState.fromJson(stateMap);
                  receiverServer.handleExternalInputState(
                    st,
                    clientAddress: remoteIp,
                    clientDeviceName: devName,
                  );
                } else {
                  final btnNames = (data['buttons'] as List<dynamic>?) ?? const [];
                  final btnSet = <GamepadButton>{};
                  for (final name in btnNames) {
                    for (final b in GamepadButton.values) {
                      if (b.name == name.toString()) {
                        btnSet.add(b);
                        break;
                      }
                    }
                  }
                  final st = ControllerState(
                    buttons: btnSet,
                    leftStick: StickState(
                      x: (data['lx'] as num?)?.toDouble() ?? 0.0,
                      y: (data['ly'] as num?)?.toDouble() ?? 0.0,
                    ),
                    rightStick: StickState(
                      x: (data['rx'] as num?)?.toDouble() ?? 0.0,
                      y: (data['ry'] as num?)?.toDouble() ?? 0.0,
                    ),
                    leftTrigger: (data['lt'] as num?)?.toDouble() ?? 0.0,
                    rightTrigger: (data['rt'] as num?)?.toDouble() ?? 0.0,
                  );
                  receiverServer.handleExternalInputState(
                    st,
                    clientAddress: remoteIp,
                    clientDeviceName: devName,
                  );
                }
              }
            } catch (_) {}
          }
        },
        onDone: () {
          _controlClients.remove(ws);
          receiverServer.handleExternalInputState(ControllerState.neutral);
        },
        onError: (_) {
          _controlClients.remove(ws);
        },
      );
      return;
    }

    // Re-open desktop dashboard window when a second instance or tray shortcut runs
    if (path == '/api/open-ui') {
      if (Platform.isWindows) {
        _launchWindowsDesktopWindow(dashboardUrl);
      }
      await _writeJson(req, {'ok': true});
      return;
    }

    // Discovery / Auto-Pair endpoint reachable from Android phone over Wi-Fi LAN & USB Tether!
    if (path == '/api/info') {
      final provider = receiverServer.gamepadProvider;
      await _writeJson(req, {
        'app': 'DartPad',
        'version': DartPadAppSettings.appVersion,
        'serverName': receiverServer.serverName,
        'udpPort': receiverServer.boundPort,
        'httpPort': guiPort,
        'ips': _resolvedIps,
        'pin': receiverServer.pairingPin,
        'deviceType': provider.deviceType.name,
        'driverActive': provider.isHardwareDriverActive,
        'driverStatus': provider.driverStatusSummary,
      });
      return;
    }

    // TCP HTTP Pairing endpoint: fixes one-way UDP where PC sees phone connect
    // but router/firewall drops UDP accept reply back to phone!
    if (path == '/api/pair' && req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      var pin = '';
      var deviceName = 'Android Controller';
      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        pin = data['pin']?.toString() ?? '';
        deviceName = data['deviceName']?.toString() ?? 'Android Controller';
      } catch (_) {}
      final res = receiverServer.handleHttpPair(
        pin: pin,
        deviceName: deviceName,
        clientAddress: req.connectionInfo?.remoteAddress.address,
      );
      await _writeJson(req, res);
      return;
    }

    if (path == '/api/unpair' && req.method == 'POST') {
      receiverServer.handleHttpUnpair();
      await _writeJson(req, {'ok': true});
      return;
    }

    if (path == '/api/ping') {
      await _writeJson(req, {
        'ok': true,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'connected': receiverServer.isClientConnected,
      });
      return;
    }

    if (path == '/api/rumble' && req.method == 'POST') {
      final sent = receiverServer.sendRumbleToClient(
        const RumbleEvent(largeMotor: 0.90, smallMotor: 0.70, durationMs: 250),
      );
      await _writeJson(req, {'ok': sent});
      return;
    }

    if (path == '/api/switch-mode' && req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      var nextType = ControllerType.xbox;
      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (data['type'] == 'playstation') {
          nextType = ControllerType.playstation;
        }
      } catch (_) {}
      final ok = receiverServer.gamepadProvider.switchDeviceType(nextType);
      await _writeJson(req, {
        'ok': ok,
        'deviceType': receiverServer.gamepadProvider.deviceType.name,
        'driverActive': receiverServer.gamepadProvider.isHardwareDriverActive,
        'driverStatus': receiverServer.gamepadProvider.driverStatusSummary,
      });
      return;
    }

    if (path == '/api/toggle-keyboard' && req.method == 'POST') {
      final provider = receiverServer.gamepadProvider;
      var enabled = false;
      if (provider is PureDartWindowsGamepadProvider) {
        provider.enableWin32KeyboardFallback =
            !provider.enableWin32KeyboardFallback;
        enabled = provider.enableWin32KeyboardFallback;
      }
      await _writeJson(req, {'ok': true, 'keyboardFallback': enabled});
      return;
    }

    if (path == '/api/install-vigem' && req.method == 'POST') {
      final result = await _installVigemDriverAndReload();
      await _writeJson(req, result);
      return;
    }

    if (path == '/api/install-shortcut' && req.method == 'POST') {
      final installed = await _installWindowsShortcutAndAutoStart();
      await _writeJson(req, {'ok': installed});
      return;
    }

    if (path == '/api/fix-network' && req.method == 'POST') {
      final fixed = await fixWindowsFirewallAndUsbMetric(silent: false);
      await _writeJson(req, {'ok': fixed});
      return;
    }

    if (path == '/api/check-update' && req.method == 'POST') {
      final info = await _checkLatestReleaseInfo();
      await _writeJson(req, info);
      return;
    }

    if (path == '/api/install-update' && req.method == 'POST') {
      final result = await _downloadAndRunWindowsUpdater();
      await _writeJson(req, result);
      if (result['ok'] == true && onShutdownRequested != null) {
        Future<void>.delayed(
          const Duration(milliseconds: 500),
          onShutdownRequested!,
        );
      }
      return;
    }

    if (path == '/api/shutdown' && req.method == 'POST') {
      await _writeJson(req, {'ok': true});
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        onShutdownRequested?.call();
      });
      return;
    }

    // Zero-Install Browser Touch Gamepad (/pad): works from ANY phone browser (Chrome / Google Lens QR)
    if (path == '/pad') {
      final pinFromUrl = req.uri.queryParameters['pin']?.trim() ?? '';
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_buildWebControllerHtml(initialPin: pinFromUrl));
      await req.response.close();
      return;
    }

    final pairingPayload = receiverServer.buildPairingPayload(
      localIp,
      allIps: _resolvedIps,
      httpPort: guiPort,
    );
    final qrSvg = _renderQrSvg(pairingPayload.toQrUriString());
    final webPadUrl = 'http://$localIp:$guiPort/pad?pin=${receiverServer.pairingPin}';
    final webQrSvg = _renderQrSvg(webPadUrl);

    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        _buildDashboardHtml(
          pairingPayload,
          qrSvg,
          webQrSvg,
          webPadUrl,
          _resolvedIps,
        ),
      );
    await req.response.close();
  }

  Future<void> _writeJson(HttpRequest req, Map<String, dynamic> body) async {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.add('Access-Control-Allow-Origin', '*')
      ..write(jsonEncode(body));
    await req.response.close();
  }

  Map<String, dynamic> _snapshotToJson(ReceiverDiagnosticsSnapshot snap) {
    final provider = receiverServer.gamepadProvider;
    final kbEnabled = provider is PureDartWindowsGamepadProvider
        ? provider.enableWin32KeyboardFallback
        : false;
    return {
      'isConnected': snap.isConnected,
      'clientAddress': snap.clientAddress,
      'clientDeviceName': snap.clientDeviceName,
      'packetsPerSecond': snap.packetsPerSecond,
      'packetLossPercent': snap.packetLossPercent,
      'droppedOutOfOrder': snap.droppedOutOfOrder,
      'lastSequence': snap.lastSequence,
      'deviceType': provider.deviceType.name,
      'driverActive': provider.isHardwareDriverActive,
      'driverStatus': provider.driverStatusSummary,
      'keyboardFallback': kbEnabled,
      'state': snap.currentState.toJson(),
    };
  }

  static Future<bool> _downloadFile(String url, File destination) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'DartPad-Windows');
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) return false;
      await destination.parent.create(recursive: true);
      final sink = destination.openWrite();
      await resp.pipe(sink);
      return await destination.exists() && await destination.length() > 1024;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _installVigemDriverAndReload() async {
    if (!Platform.isWindows) {
      return {
        'ok': false,
        'driverActive': false,
        'driverStatus': 'Hanya tersedia di Windows',
      };
    }

    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final dllFile = File('$exeDir\\ViGEmClient.dll');
      if (!dllFile.existsSync() ||
          !PureDartWindowsGamepadProvider.isValidPeExportDll(dllFile)) {
        if (dllFile.existsSync()) {
          try {
            dllFile.deleteSync();
          } catch (_) {}
        }
        var okDll = await _downloadFile(officialVigemClientAssetUrl, dllFile);
        if (!okDll) {
          okDll = await _downloadFile(fallbackVigemClientAssetUrl, dllFile);
        }
      }

      // First re-init in case DLL was just downloaded and ViGEmBus is already installed
      receiverServer.gamepadProvider.init();
      if (receiverServer.gamepadProvider.isHardwareDriverActive) {
        return {
          'ok': true,
          'driverActive': true,
          'driverStatus': receiverServer.gamepadProvider.driverStatusSummary,
        };
      }

      // Check bundled ViGEmBus setup next to DartPad.exe, otherwise download official v1.22.0
      final bundledBusExe =
          File('$exeDir\\ViGEmBus_1.22.0_x64_x86_arm64.exe');
      final tempDir = Platform.environment['TEMP'] ?? exeDir;
      final busSetup = bundledBusExe.existsSync()
          ? bundledBusExe
          : File('$tempDir\\ViGEmBus_1.22.0_x64_x86_arm64.exe');

      if (!busSetup.existsSync()) {
        final downloaded = await _downloadFile(officialVigemBusUrl, busSetup);
        if (!downloaded) {
          return {
            'ok': false,
            'driverActive': false,
            'driverStatus':
                'Gagal mengunduh ViGEmBus dari GitHub. Cek koneksi internet PC.',
          };
        }
      }

      // Run official ViGEmBus installer elevated and wait cleanly
      await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Start-Process -FilePath "${busSetup.path}" -ArgumentList "/passive /norestart" -Verb RunAs -Wait',
      ]);

      receiverServer.gamepadProvider.init();
      return {
        'ok': receiverServer.gamepadProvider.isHardwareDriverActive,
        'driverActive': receiverServer.gamepadProvider.isHardwareDriverActive,
        'driverStatus': receiverServer.gamepadProvider.driverStatusSummary,
      };
    } catch (e) {
      return {
        'ok': false,
        'driverActive': receiverServer.gamepadProvider.isHardwareDriverActive,
        'driverStatus': 'Error install ViGEmBus: $e',
      };
    }
  }

  static Future<Map<String, dynamic>> _checkLatestReleaseInfo() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req =
          await client.getUrl(Uri.parse(DartPadAppSettings.latestReleaseApiUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'DartPad-Windows');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200) {
        return {'ok': false, 'message': 'GitHub HTTP ${resp.statusCode}'};
      }
      final json =
          jsonDecode(await resp.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final tag = json['tag_name']?.toString() ?? 'v${DartPadAppSettings.appVersion}';
      final normalizedTag = tag.startsWith('v') ? tag.substring(1) : tag;
      final hasUpdate = normalizedTag != DartPadAppSettings.appVersion;

      String? setupUrl;
      final assets = (json['assets'] as List<dynamic>?) ?? const [];
      for (final a in assets) {
        if (a is Map<String, dynamic> &&
            a['name']?.toString() == 'DartPad-Setup.exe') {
          setupUrl = a['browser_download_url']?.toString();
          break;
        }
      }
      return {
        'ok': true,
        'currentVersion': DartPadAppSettings.appVersion,
        'latestTag': tag,
        'hasUpdate': hasUpdate,
        'setupUrl': setupUrl ??
            'https://github.com/ferdlcx/konsol/releases/latest/download/DartPad-Setup.exe',
      };
    } catch (e) {
      return {'ok': false, 'message': 'Gagal cek update: $e'};
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _downloadAndRunWindowsUpdater() async {
    if (!Platform.isWindows) {
      return {'ok': false, 'message': 'Hanya tersedia di Windows'};
    }
    try {
      final info = await _checkLatestReleaseInfo();
      final setupUrl = info['setupUrl']?.toString() ??
          'https://github.com/ferdlcx/konsol/releases/latest/download/DartPad-Setup.exe';
      final tempDir = Platform.environment['TEMP'] ??
          File(Platform.resolvedExecutable).parent.path;
      final outSetup = File('$tempDir\\DartPad-Setup-Update.exe');
      final ok = await _downloadFile(setupUrl, outSetup);
      if (!ok) {
        return {
          'ok': false,
          'message': 'Gagal mengunduh DartPad-Setup.exe terbaru.',
        };
      }
      await Process.start(
        outSetup.path,
        ['/SILENT', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      return {'ok': true, 'message': 'Menjalankan installer update...'};
    } catch (e) {
      return {'ok': false, 'message': 'Gagal menjalankan update: $e'};
    }
  }

  static String _renderQrSvg(String qrContent) {
    final matrix = QrPairingRenderer.generateMatrixFromText(qrContent);
    final n = matrix.length;
    const quiet = 2;
    final total = n + quiet * 2;
    final sb = StringBuffer()
      ..write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $total $total" width="184" height="184" shape-rendering="crispEdges">',
      )
      ..write('<rect width="$total" height="$total" fill="#FFFFFF" rx="1.5"/>');

    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (matrix[r][c]) {
          sb.write(
            '<rect x="${c + quiet}" y="${r + quiet}" width="1" height="1" fill="#0E0F12"/>',
          );
        }
      }
    }
    sb.write('</svg>');
    return sb.toString();
  }

  static void _launchWindowsDesktopWindow(String url) {
    Process.run(
      'cmd',
      ['/c', 'start', '', 'msedge', '--app=$url', '--window-size=1040,740'],
    ).catchError((_) {
      return Process.run('cmd', ['/c', 'start', '', url]);
    });
  }

  /// Adds Windows Firewall inbound exception for UDP 42100 & TCP 42101 AND
  /// sets USB RNDIS Tethering interface metric high (500) so LAN Ethernet internet keeps priority!
  static Future<bool> fixWindowsFirewallAndUsbMetric({bool silent = true}) async {
    if (!Platform.isWindows) return false;
    try {
      final exePath = Platform.resolvedExecutable;
      final ps = '''
netsh advfirewall firewall delete rule name="DartPad Receiver UDP" | Out-Null
netsh advfirewall firewall add rule name="DartPad Receiver UDP" dir=in action=allow protocol=UDP localport=42100 profile=any | Out-Null
netsh advfirewall firewall delete rule name="DartPad Receiver TCP" | Out-Null
netsh advfirewall firewall add rule name="DartPad Receiver TCP" dir=in action=allow protocol=TCP localport=42101 profile=any | Out-Null
netsh advfirewall firewall delete rule name="DartPad Receiver App" | Out-Null
netsh advfirewall firewall add rule name="DartPad Receiver App" dir=in action=allow program="$exePath" profile=any | Out-Null
Get-NetAdapter | Where-Object { \$_.InterfaceDescription -match "NDIS|USB|Android" } | ForEach-Object {
  Set-NetIPInterface -InterfaceIndex \$_.ifIndex -InterfaceMetric 500 -ErrorAction SilentlyContinue
}
''';
      final args = silent
          ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps]
          : [
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-Command',
              'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-NoProfile -ExecutionPolicy Bypass -Command "${ps.replaceAll('"', '\\"')}"\''
            ];
      final res = await Process.run('powershell', args);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _installWindowsShortcutAndAutoStart() async {
    if (!Platform.isWindows) return false;
    try {
      final exePath = Platform.resolvedExecutable;
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      if (localAppData.isEmpty) return false;

      final installDir = Directory('$localAppData\\Programs\\DartPad');
      if (!installDir.existsSync()) {
        installDir.createSync(recursive: true);
      }
      final targetExe = '${installDir.path}\\DartPad.exe';
      if (exePath.toLowerCase() != targetExe.toLowerCase()) {
        try {
          File(exePath).copySync(targetExe);
        } catch (_) {}
      }
      final finalExe = File(targetExe).existsSync() ? targetExe : exePath;

      final psScript = '''
\$WshShell = New-Object -ComObject WScript.Shell
\$DesktopPath = [Environment]::GetFolderPath("Desktop")
\$Shortcut = \$WshShell.CreateShortcut("\$DesktopPath\\DartPad Receiver.lnk")
\$Shortcut.TargetPath = "$finalExe"
\$Shortcut.WorkingDirectory = "${installDir.path}"
\$Shortcut.Description = "DartPad Virtual Gamepad Receiver & GUI Dashboard"
\$Shortcut.Save()

\$StartMenuPath = [Environment]::GetFolderPath("Programs")
\$SmShortcut = \$WshShell.CreateShortcut("\$StartMenuPath\\DartPad Receiver.lnk")
\$SmShortcut.TargetPath = "$finalExe"
\$SmShortcut.WorkingDirectory = "${installDir.path}"
\$SmShortcut.Save()

Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" -Name "DartPadReceiver" -Value '"\$($finalExe)"'
''';
      final res = await Process.run(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
      );
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  String _buildDashboardHtml(
    PairingPayload payload,
    String qrSvg,
    String webQrSvg,
    String webPadUrl,
    List<String> ips,
  ) {
    final provider = receiverServer.gamepadProvider;
    final driverOk = provider.isHardwareDriverActive;
    final currentMode = provider.deviceType.name;
    final kbOn = provider is PureDartWindowsGamepadProvider
        ? provider.enableWin32KeyboardFallback
        : false;
    final ipsHtml = ips.map((ip) => '<span class="ip-pill">$ip</span>').join(' ');
    final qrUri = payload.toQrUriString();

    return '''
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<title>DartPad v${DartPadAppSettings.appVersion} Studio</title>
<style>
  :root {
    --bg: #0e0f12;
    --panel: #16181d;
    --panel2: #121317;
    --line: #252830;
    --text: #f3f4f6;
    --muted: #8e95a5;
    --accent: #e5e7eb;
    --green: #22c55e;
    --amber: #f59e0b;
    --red: #ef4444;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; }
  body { background: var(--bg); color: var(--text); padding: 18px 20px; user-select: none; }
  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid var(--line); gap: 12px; }
  .brand { display: flex; align-items: center; gap: 10px; }
  .title { font-size: 16px; font-weight: 700; letter-spacing: -0.2px; }
  .ver { font-size: 11px; color: var(--muted); background: var(--panel); border: 1px solid var(--line); padding: 2px 8px; border-radius: 6px; }
  .header-right { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .badge { display: inline-flex; align-items: center; gap: 6px; padding: 6px 12px; border-radius: 8px; font-size: 12px; font-weight: 600; background: var(--panel); border: 1px solid var(--line); color: var(--muted); }
  .badge .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--muted); }
  .badge.online { color: var(--text); border-color: rgba(34, 197, 94, 0.45); background: rgba(34, 197, 94, 0.08); }
  .badge.online .dot { background: var(--green); }
  .hbtn { padding: 6px 11px; border-radius: 8px; border: 1px solid var(--line); background: var(--panel); color: var(--text); font-size: 12px; font-weight: 600; cursor: pointer; }
  .hbtn:hover { background: #1e2128; }
  .hbtn.danger { color: #fca5a5; border-color: rgba(239, 68, 68, 0.35); }
  .grid { display: grid; grid-template-columns: 320px 1fr; gap: 16px; }
  .card { background: var(--panel); border-radius: 12px; padding: 16px; border: 1px solid var(--line); }
  .card h2 { font-size: 11px; color: var(--muted); margin-bottom: 10px; text-transform: uppercase; letter-spacing: 0.9px; font-weight: 700; }
  .qr-tabs { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; background: var(--bg); padding: 3px; border-radius: 8px; border: 1px solid var(--line); margin-bottom: 10px; }
  .qr-tabs button { border: none; background: transparent; color: var(--muted); font-size: 11px; font-weight: 600; padding: 6px 8px; border-radius: 6px; cursor: pointer; }
  .qr-tabs button.active { background: var(--text); color: var(--bg); }
  .qr-box { display: flex; flex-direction: column; align-items: center; background: var(--panel2); padding: 14px; border-radius: 10px; border: 1px solid var(--line); margin-bottom: 12px; }
  .qr-hint { font-size: 10px; color: var(--muted); margin-top: 8px; text-align: center; line-height: 1.35; }
  .pin-code { font-size: 26px; font-weight: 800; letter-spacing: 5px; color: var(--text); margin-top: 10px; font-variant-numeric: tabular-nums; }
  .ip-list { display: flex; flex-wrap: wrap; gap: 6px; margin: 6px 0 10px 0; }
  .ip-pill { background: var(--panel2); border: 1px solid var(--line); color: var(--text); padding: 3px 8px; border-radius: 6px; font-size: 11px; font-weight: 600; user-select: text; font-family: monospace; }
  .info-row { display: flex; justify-content: space-between; font-size: 12px; padding: 6px 0; border-bottom: 1px solid var(--line); color: var(--muted); }
  .info-row strong { color: var(--text); font-weight: 600; }
  .uri-box { margin-top: 8px; background: var(--panel2); padding: 7px 9px; border-radius: 8px; font-size: 10px; color: var(--muted); word-break: break-all; user-select: text; border: 1px solid var(--line); font-family: monospace; }
  .btn { width: 100%; margin-top: 8px; padding: 9px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel2); color: var(--text); font-weight: 600; cursor: pointer; font-size: 12px; transition: background 0.12s; }
  .btn:hover { background: #1e2128; }
  .btn.primary { background: var(--text); color: var(--bg); border-color: var(--text); }
  .btn.primary:hover { opacity: 0.9; background: var(--text); }
  .btn.amber { background: rgba(245, 158, 11, 0.12); border-color: rgba(245, 158, 11, 0.45); color: #fbbf24; }
  .driver-banner { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 10px; border: 1px solid var(--line); background: var(--panel2); margin-bottom: 14px; }
  .driver-banner.ok { border-color: rgba(34, 197, 94, 0.4); background: rgba(34, 197, 94, 0.06); }
  .driver-banner.warn { border-color: rgba(245, 158, 11, 0.45); background: rgba(245, 158, 11, 0.08); }
  .driver-title { font-size: 13px; font-weight: 700; }
  .driver-sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
  .mode-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 14px; padding: 10px 12px; background: var(--panel2); border-radius: 10px; border: 1px solid var(--line); }
  .seg { display: inline-flex; background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 2px; gap: 2px; }
  .seg button { border: none; background: transparent; color: var(--muted); padding: 6px 12px; font-size: 11px; font-weight: 600; border-radius: 6px; cursor: pointer; }
  .seg button.active { background: var(--text); color: var(--bg); }
  .controller-stage { display: flex; flex-direction: column; }
  .metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; margin-bottom: 14px; }
  .metric-box { background: var(--panel2); padding: 10px; border-radius: 8px; border: 1px solid var(--line); text-align: center; }
  .metric-val { font-size: 18px; font-weight: 700; color: var(--text); font-variant-numeric: tabular-nums; }
  .metric-lbl { font-size: 10px; color: var(--muted); margin-top: 2px; text-transform: uppercase; letter-spacing: 0.5px; }
  .buttons-grid { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
  .gbtn { padding: 6px 10px; border-radius: 6px; background: var(--panel2); border: 1px solid var(--line); font-size: 11px; font-weight: 600; color: var(--muted); }
  .gbtn.active { background: var(--text); color: var(--bg); border-color: var(--text); }
  .sticks-row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .stick-box { background: var(--panel2); padding: 12px; border-radius: 10px; border: 1px solid var(--line); display: flex; flex-direction: column; align-items: center; }
  .stick-circle { width: 92px; height: 92px; border-radius: 50%; border: 1px solid #303540; position: relative; margin: 8px 0; background: var(--bg); }
  .stick-dot { width: 16px; height: 16px; border-radius: 50%; background: var(--text); position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); }
  .trigger-bar { width: 100%; height: 6px; background: var(--bg); border-radius: 4px; overflow: hidden; margin-top: 6px; border: 1px solid var(--line); }
  .trigger-fill { height: 100%; width: 0%; background: var(--text); transition: width 0.04s; }
</style>
</head>
<body>
  <div class="header">
    <div class="brand">
      <div class="title">DartPad</div>
      <span class="ver">v${DartPadAppSettings.appVersion}</span>
    </div>
    <div class="header-right">
      <div id="connBadge" class="badge"><span class="dot"></span><span>Menunggu HP...</span></div>
      <button id="updBtn" class="hbtn" onclick="checkUpdate()">Cek Update</button>
      <button class="hbtn danger" onclick="shutdownApp()">Matikan DartPad</button>
    </div>
  </div>

  <div class="grid">
    <div class="card">
      <h2>Pairing QR, PIN &amp; Web Controller</h2>
      <div class="qr-tabs">
        <button id="tabApk" class="active" onclick="setQrTab('apk')">QR APK DartPad</button>
        <button id="tabWeb" onclick="setQrTab('web')">QR Browser (/pad)</button>
      </div>
      <div class="qr-box">
        <div id="qrApkWrap">$qrSvg</div>
        <div id="qrWebWrap" style="display:none;">$webQrSvg</div>
        <div class="pin-code">${payload.pin}</div>
        <div id="qrHint" class="qr-hint">Scan pakai APK DartPad (Hybrid UDP + TCP WebSocket).</div>
      </div>
      <div style="font-size:11px;color:var(--muted);">IP PC (LAN / Wi-Fi / USB Tether):</div>
      <div class="ip-list">$ipsHtml</div>
      <div class="info-row"><span>UDP / HTTP Port</span><strong>${payload.port} / ${payload.httpPort}</strong></div>
      <div class="info-row"><span>Nama PC</span><strong>${payload.deviceName}</strong></div>
      <div id="uriBox" class="uri-box" title="Pairing URI">$qrUri</div>
      <button class="btn primary" onclick="testRumble()">Test Getar (Rumble) ke HP</button>
      <button id="fwBtn" class="btn" onclick="fixFirewall()">Izinkan Firewall &amp; USB Tether LAN</button>
      <button id="installBtn" class="btn" onclick="installShortcut()">Pasang Shortcut &amp; Auto-Start</button>
    </div>

    <div class="card controller-stage">
      <h2>Virtual Gamepad Driver &amp; Live Monitor</h2>

      <div id="driverBanner" class="driver-banner ${driverOk ? 'ok' : 'warn'}">
        <div>
          <div id="driverTitle" class="driver-title">${driverOk ? 'Driver Gamepad Aktif — Terbaca di Game PC' : 'Driver Gamepad (ViGEmBus) Belum Aktif'}</div>
          <div id="driverSub" class="driver-sub">${provider.driverStatusSummary}</div>
        </div>
        ${driverOk ? '' : '<button id="vigemBtn" class="btn amber" style="width:auto;margin-top:0;white-space:nowrap;" onclick="installVigem()">Pasang ViGEmBus</button>'}
      </div>

      <div class="mode-row">
        <div>
          <div style="font-size:12px;font-weight:600;">Identitas Controller di Windows &amp; Game</div>
          <div style="font-size:11px;color:var(--muted);">Pilih Sony DS4 agar game PC menampilkan tombol PS (△ ○ □ ✕)</div>
        </div>
        <div class="seg">
          <button id="modeXbox" class="${currentMode == 'xbox' ? 'active' : ''}" onclick="switchMode('xbox')">Xbox 360</button>
          <button id="modePs" class="${currentMode == 'playstation' ? 'active' : ''}" onclick="switchMode('playstation')">Sony PS4 (DS4)</button>
        </div>
      </div>

      <div class="metrics">
        <div class="metric-box"><div id="ppsVal" class="metric-val">0 Hz</div><div class="metric-lbl">Input Rate</div></div>
        <div class="metric-box"><div id="lossVal" class="metric-val">0.0%</div><div class="metric-lbl">Packet Loss</div></div>
        <div class="metric-box"><div id="seqVal" class="metric-val">#0</div><div class="metric-lbl">Sequence</div></div>
      </div>

      <div id="btnContainer" class="buttons-grid"></div>

      <div class="sticks-row">
        <div class="stick-box">
          <strong style="font-size:11px;color:var(--muted);">LEFT STICK &amp; LT</strong>
          <div class="stick-circle"><div id="lsDot" class="stick-dot"></div></div>
          <div id="lsText" style="font-size:11px;color:var(--muted);font-family:monospace;">0.00 , 0.00</div>
          <div class="trigger-bar"><div id="ltFill" class="trigger-fill"></div></div>
        </div>
        <div class="stick-box">
          <strong style="font-size:11px;color:var(--muted);">RIGHT STICK &amp; RT</strong>
          <div class="stick-circle"><div id="rsDot" class="stick-dot"></div></div>
          <div id="rsText" style="font-size:11px;color:var(--muted);font-family:monospace;">0.00 , 0.00</div>
          <div class="trigger-bar"><div id="rtFill" class="trigger-fill"></div></div>
        </div>
      </div>

      <div style="margin-top:10px;display:flex;justify-content:space-between;align-items:center;">
        <span style="font-size:11px;color:var(--muted);">Alternatif tanpa APK: buka <strong>$webPadUrl</strong> di browser HP.</span>
        <button id="kbBtn" class="hbtn" onclick="toggleKb()">Keyboard Fallback: ${kbOn ? 'ON' : 'OFF'}</button>
      </div>
    </div>
  </div>

<script>
const APK_URI = ${jsonEncode(qrUri)};
const WEB_PAD_URL = ${jsonEncode(webPadUrl)};

function setQrTab(tab) {
  const isWeb = tab === 'web';
  document.getElementById('tabApk').className = isWeb ? '' : 'active';
  document.getElementById('tabWeb').className = isWeb ? 'active' : '';
  document.getElementById('qrApkWrap').style.display = isWeb ? 'none' : 'block';
  document.getElementById('qrWebWrap').style.display = isWeb ? 'block' : 'none';
  document.getElementById('uriBox').textContent = isWeb ? WEB_PAD_URL : APK_URI;
  document.getElementById('qrHint').textContent = isWeb
      ? 'Scan pakai Google Lens / Kamera HP, atau buka URL di Chrome untuk main langsung!'
      : 'Scan pakai APK DartPad (Hybrid UDP + TCP WebSocket).';
}

const ALL_BUTTONS = [
  ['south','A / ✕'], ['east','B / ○'], ['west','X / □'], ['north','Y / △'],
  ['leftShoulder','LB / L1'], ['rightShoulder','RB / R1'], ['leftTrigger','LT / L2'], ['rightTrigger','RT / R2'],
  ['dpadUp','Up'], ['dpadDown','Down'], ['dpadLeft','Left'], ['dpadRight','Right'],
  ['select','View / Share'], ['guide','Guide / PS'], ['start','Menu / Options'], ['leftStick','L3'], ['rightStick','R3']
];
const btnContainer = document.getElementById('btnContainer');
ALL_BUTTONS.forEach(([id, label]) => {
  const el = document.createElement('div');
  el.className = 'gbtn';
  el.id = 'btn_' + id;
  el.textContent = label;
  btnContainer.appendChild(el);
});

const ws = new WebSocket('ws://' + location.host + '/ws');
ws.onmessage = (ev) => {
  const data = JSON.parse(ev.data);
  const badge = document.getElementById('connBadge');
  if (data.isConnected) {
    badge.className = 'badge online';
    badge.innerHTML = '<span class="dot"></span><span>Terhubung: ' + (data.clientDeviceName || 'Android') + '</span>';
  } else {
    badge.className = 'badge';
    badge.innerHTML = '<span class="dot"></span><span>Menunggu HP...</span>';
  }
  document.getElementById('ppsVal').textContent = data.packetsPerSecond + ' Hz';
  document.getElementById('lossVal').textContent = data.packetLossPercent.toFixed(1) + '%';
  document.getElementById('seqVal').textContent = '#' + data.lastSequence;

  if (data.deviceType) {
    document.getElementById('modeXbox').className = data.deviceType === 'xbox' ? 'active' : '';
    document.getElementById('modePs').className = data.deviceType === 'playstation' ? 'active' : '';
  }
  if (typeof data.driverActive === 'boolean') {
    const banner = document.getElementById('driverBanner');
    banner.className = 'driver-banner ' + (data.driverActive ? 'ok' : 'warn');
    document.getElementById('driverTitle').textContent = data.driverActive
        ? 'Driver Gamepad Aktif — Terbaca di Game PC'
        : 'Driver Gamepad (ViGEmBus) Belum Aktif';
    if (data.driverStatus) {
      document.getElementById('driverSub').textContent = data.driverStatus;
    }
    const vBtn = document.getElementById('vigemBtn');
    if (vBtn && data.driverActive) vBtn.remove();
  }

  const st = data.state;
  const activeSet = new Set(st.buttons || []);
  ALL_BUTTONS.forEach(([id]) => {
    const el = document.getElementById('btn_' + id);
    if (activeSet.has(id)) el.classList.add('active');
    else el.classList.remove('active');
  });

  const lx = st.leftStick.x || 0, ly = st.leftStick.y || 0;
  const rx = st.rightStick.x || 0, ry = st.rightStick.y || 0;
  document.getElementById('lsDot').style.left = (50 + lx * 42) + '%';
  document.getElementById('lsDot').style.top = (50 - ly * 42) + '%';
  document.getElementById('lsText').textContent = lx.toFixed(2) + ' , ' + ly.toFixed(2);

  document.getElementById('rsDot').style.left = (50 + rx * 42) + '%';
  document.getElementById('rsDot').style.top = (50 - ry * 42) + '%';
  document.getElementById('rsText').textContent = rx.toFixed(2) + ' , ' + ry.toFixed(2);

  document.getElementById('ltFill').style.width = ((st.leftTrigger || 0) * 100) + '%';
  document.getElementById('rtFill').style.width = ((st.rightTrigger || 0) * 100) + '%';
};

function testRumble() {
  fetch('/api/rumble', { method: 'POST' });
}

async function switchMode(type) {
  const res = await fetch('/api/switch-mode', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type })
  });
  const json = await res.json();
  document.getElementById('modeXbox').className = json.deviceType === 'xbox' ? 'active' : '';
  document.getElementById('modePs').className = json.deviceType === 'playstation' ? 'active' : '';
  document.getElementById('driverSub').textContent = json.driverStatus;
}

async function installVigem() {
  const btn = document.getElementById('vigemBtn');
  if (btn) btn.textContent = 'Mengunduh & Memasang...';
  document.getElementById('driverSub').textContent = 'Mengunduh ViGEmBus v1.22.0 resmi...';
  const res = await fetch('/api/install-vigem', { method: 'POST' });
  const json = await res.json();
  document.getElementById('driverSub').textContent = json.driverStatus;
  if (json.driverActive) {
    document.getElementById('driverBanner').className = 'driver-banner ok';
    document.getElementById('driverTitle').textContent = 'Driver Gamepad Aktif — Terbaca di Game PC';
    if (btn) btn.remove();
  } else if (btn) {
    btn.textContent = 'Coba Pasang Ulang';
  }
}

async function toggleKb() {
  const res = await fetch('/api/toggle-keyboard', { method: 'POST' });
  const json = await res.json();
  document.getElementById('kbBtn').textContent = 'Keyboard Fallback: ' + (json.keyboardFallback ? 'ON' : 'OFF');
}

async function fixFirewall() {
  const btn = document.getElementById('fwBtn');
  btn.textContent = 'Mengatur Firewall...';
  const res = await fetch('/api/fix-network', { method: 'POST' });
  const json = await res.json();
  btn.textContent = json.ok ? 'Firewall & USB Tether Diatur' : 'Jalankan sbg Admin jika gagal';
}

async function installShortcut() {
  const btn = document.getElementById('installBtn');
  btn.textContent = 'Memasang Shortcut...';
  const res = await fetch('/api/install-shortcut', { method: 'POST' });
  const json = await res.json();
  btn.textContent = json.ok ? 'Shortcut & Auto-Start Terpasang' : 'Hanya untuk Windows';
}

let pendingUpdateReady = false;
async function checkUpdate() {
  const btn = document.getElementById('updBtn');
  if (pendingUpdateReady) {
    btn.textContent = 'Mengunduh Setup...';
    const res = await fetch('/api/install-update', { method: 'POST' });
    const json = await res.json();
    btn.textContent = json.message;
    return;
  }
  btn.textContent = 'Mengecek...';
  const res = await fetch('/api/check-update', { method: 'POST' });
  const json = await res.json();
  if (!json.ok) {
    btn.textContent = json.message || 'Gagal cek';
    return;
  }
  if (json.hasUpdate) {
    pendingUpdateReady = true;
    btn.textContent = 'Update ke ' + json.latestTag;
  } else {
    btn.textContent = 'Versi Terbaru (' + json.latestTag + ')';
  }
}

async function shutdownApp() {
  await fetch('/api/shutdown', { method: 'POST' });
  window.close();
}
</script>
</body>
</html>
''';
  }

  /// Zero-Install Landscape Mobile Touch Gamepad served directly at `http://<PC_IP>:42101/pad`.
  /// Connects over TCP WebSocket `/ws-control` so it works cleanly even if camera permissions
  /// or UDP broadcasts fail!
  String _buildWebControllerHtml({String initialPin = ''}) {
    return '''
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<title>DartPad Web Controller</title>
<style>
  :root {
    --bg: #0e0f12;
    --panel: #16181d;
    --line: #282c36;
    --text: #f3f4f6;
    --muted: #8e95a5;
    --accent: #e5e7eb;
    --green: #22c55e;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; touch-action: none; }
  html, body { width: 100%; height: 100%; overflow: hidden; background: var(--bg); color: var(--text); font-family: system-ui, -apple-system, sans-serif; }
  .pad-root { position: relative; width: 100%; height: 100%; }
  .topbar {
    position: absolute; top: 8px; left: 50%; transform: translateX(-50%);
    display: flex; align-items: center; gap: 8px; z-index: 20;
    background: rgba(22, 24, 29, 0.92); border: 1px solid var(--line);
    padding: 5px 10px; border-radius: 999px; font-size: 11px;
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #f59e0b; }
  .dot.ok { background: var(--green); }
  .tbtn { border: 1px solid var(--line); background: #1e2128; color: var(--text); border-radius: 999px; padding: 3px 9px; font-size: 10px; font-weight: 700; cursor: pointer; }
  .btn {
    position: absolute; display: flex; align-items: center; justify-content: center;
    background: var(--panel); border: 1.5px solid #323746; color: var(--text);
    font-weight: 700; border-radius: 50%; transition: transform 0.04s, background 0.04s;
  }
  .btn.pill { border-radius: 10px; font-size: 12px; }
  .btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); transform: scale(0.93); }
  .stick-base {
    position: absolute; border-radius: 50%; background: rgba(22,24,29,0.72);
    border: 1.5px solid #303544; display: flex; align-items: center; justify-content: center;
  }
  .stick-knob {
    width: 44%; height: 44%; border-radius: 50%; background: #d4d7dd;
    box-shadow: 0 2px 10px rgba(0,0,0,0.6); pointer-events: none;
  }
  .pin-modal {
    position: fixed; inset: 0; background: rgba(10,11,14,0.92); z-index: 40;
    display: flex; align-items: center; justify-content: center; padding: 20px;
  }
  .pin-card {
    width: 100%; max-width: 320px; background: var(--panel); border: 1px solid var(--line);
    border-radius: 14px; padding: 18px; text-align: center;
  }
  .pin-card input {
    width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line);
    background: var(--bg); color: var(--text); font-size: 20px; text-align: center;
    letter-spacing: 6px; margin: 12px 0; touch-action: auto; user-select: text;
  }
  .pin-card button {
    width: 100%; padding: 10px; border-radius: 8px; border: none;
    background: var(--text); color: var(--bg); font-weight: 700; font-size: 13px; cursor: pointer;
  }
</style>
</head>
<body>
  <div class="topbar">
    <span id="wsDot" class="dot"></span>
    <span id="wsLabel">WebPad</span>
    <button class="tbtn" onclick="toggleMode()">Xbox/PS</button>
    <button class="tbtn" onclick="goFullscreen()">Fullscreen</button>
  </div>

  <div id="padRoot" class="pad-root">
    <!-- Left & Right Shoulders / Triggers -->
    <div class="btn pill" data-btn="leftTrigger" style="left:3%;top:6%;width:13%;height:11%;">LT</div>
    <div class="btn pill" data-btn="leftShoulder" style="left:3%;top:19%;width:13%;height:10%;">LB</div>
    <div class="btn pill" data-btn="rightTrigger" style="right:3%;top:6%;width:13%;height:11%;">RT</div>
    <div class="btn pill" data-btn="rightShoulder" style="right:3%;top:19%;width:13%;height:10%;">RB</div>

    <!-- Center Menu Buttons -->
    <div class="btn pill" data-btn="select" style="left:36%;top:16%;width:8%;height:9%;">VIEW</div>
    <div class="btn pill" data-btn="guide" style="left:46%;top:16%;width:8%;height:9%;">HOME</div>
    <div class="btn pill" data-btn="start" style="left:56%;top:16%;width:8%;height:9%;">MENU</div>

    <!-- Left Stick & L3 -->
    <div id="lsBase" class="stick-base" style="left:5%;top:36%;width:21vw;height:21vw;max-width:155px;max-height:155px;">
      <div id="lsKnob" class="stick-knob"></div>
    </div>
    <div class="btn pill" data-btn="leftStick" style="left:6%;bottom:6%;width:9%;height:10%;">L3</div>

    <!-- D-Pad -->
    <div class="btn pill" data-btn="dpadUp" style="left:28%;top:50%;width:7.5%;height:11%;">▲</div>
    <div class="btn pill" data-btn="dpadDown" style="left:28%;top:74%;width:7.5%;height:11%;">▼</div>
    <div class="btn pill" data-btn="dpadLeft" style="left:20%;top:62%;width:7.5%;height:11%;">◀</div>
    <div class="btn pill" data-btn="dpadRight" style="left:36%;top:62%;width:7.5%;height:11%;">▶</div>

    <!-- Right Face Buttons (Xbox/PS) -->
    <div class="btn" id="bNorth" data-btn="north" style="right:11%;top:35%;width:58px;height:58px;">Y</div>
    <div class="btn" id="bWest" data-btn="west" style="right:18%;top:49%;width:58px;height:58px;">X</div>
    <div class="btn" id="bEast" data-btn="east" style="right:4%;top:49%;width:58px;height:58px;">B</div>
    <div class="btn" id="bSouth" data-btn="south" style="right:11%;top:63%;width:58px;height:58px;">A</div>

    <!-- Right Stick & R3 -->
    <div id="rsBase" class="stick-base" style="right:25%;bottom:8%;width:18vw;height:18vw;max-width:132px;max-height:132px;">
      <div id="rsKnob" class="stick-knob"></div>
    </div>
    <div class="btn pill" data-btn="rightStick" style="right:6%;bottom:6%;width:9%;height:10%;">R3</div>
  </div>

  <div id="pinModal" class="pin-modal" style="display:none;">
    <div class="pin-card">
      <div style="font-weight:700;font-size:15px;">Sambung Web Controller</div>
      <div style="font-size:12px;color:#8e95a5;margin-top:4px;">Masukkan PIN 6-Digit dari jendela DartPad PC</div>
      <input id="pinInput" type="tel" maxlength="6" placeholder="123456">
      <button onclick="connectFromInput()">Hubungkan Sekarang</button>
    </div>
  </div>

<script>
let currentPin = ${jsonEncode(initialPin)};
let ws = null;
let psMode = false;
const pressedMap = new Map();
const activeButtons = new Set();
let lx = 0, ly = 0, rx = 0, ry = 0;

function toggleMode() {
  psMode = !psMode;
  document.getElementById('bNorth').textContent = psMode ? '△' : 'Y';
  document.getElementById('bWest').textContent = psMode ? '□' : 'X';
  document.getElementById('bEast').textContent = psMode ? '○' : 'B';
  document.getElementById('bSouth').textContent = psMode ? '✕' : 'A';
}

function goFullscreen() {
  const docEl = document.documentElement;
  if (!document.fullscreenElement && docEl.requestFullscreen) {
    docEl.requestFullscreen().catch(() => {});
  } else if (document.exitFullscreen) {
    document.exitFullscreen().catch(() => {});
  }
}

function syncButtons() {
  activeButtons.clear();
  pressedMap.forEach((btn) => activeButtons.add(btn));
  document.querySelectorAll('[data-btn]').forEach((el) => {
    const b = el.getAttribute('data-btn');
    if (activeButtons.has(b)) el.classList.add('active');
    else el.classList.remove('active');
  });
  sendState();
}

function sendState() {
  if (!ws || ws.readyState !== 1) return;
  const lt = activeButtons.has('leftTrigger') ? 1.0 : 0.0;
  const rt = activeButtons.has('rightTrigger') ? 1.0 : 0.0;
  ws.send(JSON.stringify({
    type: 'input',
    buttons: Array.from(activeButtons),
    lx: lx, ly: ly, rx: rx, ry: ry, lt: lt, rt: rt
  }));
}

document.querySelectorAll('[data-btn]').forEach((el) => {
  const btn = el.getAttribute('data-btn');
  el.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    pressedMap.set(e.pointerId, btn);
    if (navigator.vibrate) navigator.vibrate(14);
    syncButtons();
  });
  const release = (e) => {
    if (pressedMap.has(e.pointerId)) {
      pressedMap.delete(e.pointerId);
      syncButtons();
    }
  };
  el.addEventListener('pointerup', release);
  el.addEventListener('pointercancel', release);
});

function bindStick(baseId, knobId, onMove) {
  const base = document.getElementById(baseId);
  const knob = document.getElementById(knobId);
  let activePid = null;

  function updateFromEvent(e) {
    const rect = base.getBoundingClientRect();
    const cx = rect.left + rect.width / 2;
    const cy = rect.top + rect.height / 2;
    const radius = rect.width * 0.42;
    let dx = (e.clientX - cx) / radius;
    let dy = (e.clientY - cy) / radius;
    const mag = Math.hypot(dx, dy);
    if (mag > 1) { dx /= mag; dy /= mag; }
    knob.style.transform = 'translate(' + (dx * radius * 0.65) + 'px, ' + (dy * radius * 0.65) + 'px)';
    onMove(dx, -dy);
    sendState();
  }

  base.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    activePid = e.pointerId;
    base.setPointerCapture(e.pointerId);
    updateFromEvent(e);
  });
  base.addEventListener('pointermove', (e) => {
    if (e.pointerId === activePid) updateFromEvent(e);
  });
  const endStick = (e) => {
    if (e.pointerId === activePid) {
      activePid = null;
      knob.style.transform = 'translate(0px, 0px)';
      onMove(0, 0);
      sendState();
    }
  };
  base.addEventListener('pointerup', endStick);
  base.addEventListener('pointercancel', endStick);
}

bindStick('lsBase', 'lsKnob', (x, y) => { lx = x; ly = y; });
bindStick('rsBase', 'rsKnob', (x, y) => { rx = x; ry = y; });

function connectWs(pin) {
  const wsUrl = 'ws://' + location.host + '/ws-control?pin=' + encodeURIComponent(pin) + '&name=Browser-WebPad';
  ws = new WebSocket(wsUrl);
  ws.onopen = () => {
    document.getElementById('pinModal').style.display = 'none';
    document.getElementById('wsDot').className = 'dot ok';
    document.getElementById('wsLabel').textContent = 'Terhubung (WebPad)';
  };
  ws.onmessage = (ev) => {
    try {
      const msg = JSON.parse(ev.data);
      if (msg.type === 'rumble' && navigator.vibrate) {
        navigator.vibrate(msg.durationMs || 80);
      }
    } catch (_) {}
  };
  ws.onclose = () => {
    document.getElementById('wsDot').className = 'dot';
    document.getElementById('wsLabel').textContent = 'Terputus - Reconnecting...';
    setTimeout(() => connectWs(pin), 1500);
  };
}

function connectFromInput() {
  const val = document.getElementById('pinInput').value.trim();
  if (val) {
    currentPin = val;
    connectWs(currentPin);
  }
}

setInterval(() => {
  if (ws && ws.readyState === 1) sendState();
}, 35);

if (currentPin) {
  connectWs(currentPin);
} else {
  document.getElementById('pinModal').style.display = 'flex';
}
</script>
</body>
</html>
''';
  }
}

typedef VoidCallback = void Function();
