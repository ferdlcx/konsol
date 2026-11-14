import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';

import '../diagnostics/qr_pairing_renderer.dart';
import '../network/receiver_server.dart';
import '../virtual_device/pure_dart_windows_provider.dart';

/// Embedded Desktop GUI Dashboard & HTTP Discovery API Server built directly into
/// `DartPad.exe`.
class EmbeddedDashboardGui {
  static const String officialVigemBusUrl =
      'https://github.com/nefarius/ViGEmBus/releases/download/v1.22.0/ViGEmBus_1.22.0_x64_x86_arm64.exe';
  static const String officialVigemClientAssetUrl =
      'https://github.com/ferdlcx/konsol/releases/latest/download/ViGEmClient.dll';

  final DartPadReceiverServer receiverServer;
  final String localIp;
  final List<String> allIps;
  final int preferredPort;
  final VoidCallback? onShutdownRequested;

  HttpServer? _httpServer;
  final Set<WebSocket> _clients = {};

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
    for (final ws in _clients) {
      await ws.close();
    }
    _clients.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;

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

    final pairingPayload = receiverServer.buildPairingPayload(
      localIp,
      allIps: _resolvedIps,
      httpPort: guiPort,
    );
    final qrSvg = _renderQrSvg(pairingPayload);

    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_buildDashboardHtml(pairingPayload, qrSvg, _resolvedIps));
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
      if (!dllFile.existsSync()) {
        await _downloadFile(officialVigemClientAssetUrl, dllFile);
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

  static String _renderQrSvg(PairingPayload payload) {
    final matrix = QrPairingRenderer.generateMatrix(payload);
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
  .grid { display: grid; grid-template-columns: 310px 1fr; gap: 16px; }
  .card { background: var(--panel); border-radius: 12px; padding: 16px; border: 1px solid var(--line); }
  .card h2 { font-size: 11px; color: var(--muted); margin-bottom: 12px; text-transform: uppercase; letter-spacing: 0.9px; font-weight: 700; }
  .qr-box { display: flex; flex-direction: column; align-items: center; background: var(--panel2); padding: 14px; border-radius: 10px; border: 1px solid var(--line); margin-bottom: 12px; }
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
      <h2>Pairing QR &amp; PIN</h2>
      <div class="qr-box">
        $qrSvg
        <div class="pin-code">${payload.pin}</div>
      </div>
      <div style="font-size:11px;color:var(--muted);">IP PC (LAN / Wi-Fi / USB Tether):</div>
      <div class="ip-list">$ipsHtml</div>
      <div class="info-row"><span>UDP / HTTP Port</span><strong>${payload.port} / ${payload.httpPort}</strong></div>
      <div class="info-row"><span>Nama PC</span><strong>${payload.deviceName}</strong></div>
      <div class="uri-box" title="QR URI">${qrUri}</div>
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
        <span style="font-size:11px;color:var(--muted);">Cmd window otomatis disembunyikan agar tidak berkedip.</span>
        <button id="kbBtn" class="hbtn" onclick="toggleKb()">Keyboard Fallback: ${kbOn ? 'ON' : 'OFF'}</button>
      </div>
    </div>
  </div>

<script>
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
}

typedef VoidCallback = void Function();
