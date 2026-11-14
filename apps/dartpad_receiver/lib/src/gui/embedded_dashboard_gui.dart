import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';

import '../diagnostics/qr_pairing_renderer.dart';
import '../network/receiver_server.dart';

/// Embedded Desktop GUI Dashboard & HTTP Discovery API Server built directly into
/// the single `DartPad.exe` binary.
class EmbeddedDashboardGui {
  final DartPadReceiverServer receiverServer;
  final String localIp;
  final List<String> allIps;
  final int preferredPort;

  HttpServer? _httpServer;
  final Set<WebSocket> _clients = {};

  EmbeddedDashboardGui({
    required this.receiverServer,
    required this.localIp,
    this.allIps = const [],
    this.preferredPort = 42101,
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

  /// Starts the HTTP Discovery API + GUI server on `0.0.0.0:42101` (or ephemeral
  /// fallback) and optionally opens the native desktop window on Windows.
  Future<void> start({bool openDesktopWindow = true, bool bindLoopbackOnly = false}) async {
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

    // Discovery / Auto-Pair endpoint reachable from Android phone over Wi-Fi LAN & USB Tether!
    if (path == '/api/info') {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..headers.add('Access-Control-Allow-Origin', '*')
        ..write(
          jsonEncode({
            'app': 'DartPad',
            'version': DartPadAppSettings.appVersion,
            'serverName': receiverServer.serverName,
            'udpPort': receiverServer.boundPort,
            'httpPort': guiPort,
            'ips': _resolvedIps,
            'pin': receiverServer.pairingPin,
          }),
        );
      await req.response.close();
      return;
    }

    if (path == '/api/rumble' && req.method == 'POST') {
      final sent = receiverServer.sendRumbleToClient(
        const RumbleEvent(largeMotor: 0.90, smallMotor: 0.70, durationMs: 250),
      );
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': sent}));
      await req.response.close();
      return;
    }

    if (path == '/api/install-shortcut' && req.method == 'POST') {
      final installed = await _installWindowsShortcutAndAutoStart();
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': installed}));
      await req.response.close();
      return;
    }

    if (path == '/api/fix-network' && req.method == 'POST') {
      final fixed = await fixWindowsFirewallAndUsbMetric(silent: false);
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': fixed}));
      await req.response.close();
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

  Map<String, dynamic> _snapshotToJson(ReceiverDiagnosticsSnapshot snap) {
    return {
      'isConnected': snap.isConnected,
      'clientAddress': snap.clientAddress,
      'clientDeviceName': snap.clientDeviceName,
      'packetsPerSecond': snap.packetsPerSecond,
      'packetLossPercent': snap.packetLossPercent,
      'droppedOutOfOrder': snap.droppedOutOfOrder,
      'lastSequence': snap.lastSequence,
      'state': snap.currentState.toJson(),
    };
  }

  static String _renderQrSvg(PairingPayload payload) {
    final matrix = QrPairingRenderer.generateMatrix(payload);
    final n = matrix.length;
    final quiet = 2;
    final total = n + quiet * 2;
    final sb = StringBuffer()
      ..write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $total $total" width="196" height="196" shape-rendering="crispEdges">',
      )
      ..write('<rect width="$total" height="$total" fill="#FFFFFF" rx="1.5"/>');

    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (matrix[r][c]) {
          sb.write(
            '<rect x="${c + quiet}" y="${r + quiet}" width="1" height="1" fill="#0B0E14"/>',
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
      ['/c', 'start', '', 'msedge', '--app=$url', '--window-size=1020,720'],
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

  static String _buildDashboardHtml(
    PairingPayload payload,
    String qrSvg,
    List<String> ips,
  ) {
    final ipsHtml = ips
        .map((ip) => '<span class="ip-pill">$ip</span>')
        .join(' ');
    final qrUri = payload.toQrUriString();

    return '''
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<title>DartPad v${DartPadAppSettings.appVersion} Windows Dashboard</title>
<style>
  :root {
    --bg: #0b0e14;
    --panel: #141a24;
    --accent: #00e5ff;
    --pink: #ff4081;
    --green: #00e676;
    --amber: #ffab00;
    --text: #f0f4f8;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', system-ui, sans-serif; }
  body { background: var(--bg); color: var(--text); padding: 18px; user-select: none; }
  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; padding-bottom: 10px; border-bottom: 1px solid #222c3c; }
  .title { font-size: 19px; font-weight: 800; color: var(--accent); }
  .badge { padding: 6px 14px; border-radius: 20px; font-size: 12px; font-weight: 700; background: #232d3f; }
  .badge.online { background: rgba(0, 230, 118, 0.18); color: var(--green); border: 1px solid var(--green); }
  .grid { display: grid; grid-template-columns: 320px 1fr; gap: 18px; }
  .card { background: var(--panel); border-radius: 16px; padding: 16px; border: 1px solid #202938; }
  .card h2 { font-size: 14px; color: #9fb0c7; margin-bottom: 10px; text-transform: uppercase; letter-spacing: 0.6px; }
  .qr-box { display: flex; flex-direction: column; align-items: center; background: #0e131b; padding: 14px; border-radius: 12px; margin-bottom: 12px; }
  .pin-code { font-size: 28px; font-weight: 900; letter-spacing: 5px; color: var(--accent); margin-top: 8px; }
  .ip-list { display: flex; flex-wrap: wrap; gap: 6px; margin: 6px 0 8px 0; }
  .ip-pill { background: #1c2636; border: 1px solid #2d3c54; color: var(--green); padding: 3px 8px; border-radius: 8px; font-size: 12px; font-weight: 700; user-select: text; }
  .info-row { display: flex; justify-content: space-between; font-size: 12px; padding: 5px 0; border-bottom: 1px solid #1c2432; }
  .uri-box { margin-top: 8px; background: #0b0e14; padding: 6px 8px; border-radius: 8px; font-size: 10px; color: #8496ae; word-break: break-all; user-select: text; border: 1px solid #202938; }
  .btn { width: 100%; margin-top: 8px; padding: 10px; border: none; border-radius: 10px; background: var(--pink); color: #fff; font-weight: 700; cursor: pointer; font-size: 12px; transition: 0.15s; }
  .btn.secondary { background: #1a2434; border: 1px solid var(--accent); color: var(--accent); }
  .btn.warn { background: #261d12; border: 1px solid var(--amber); color: var(--amber); }
  .btn:hover { opacity: 0.92; transform: translateY(-1px); }
  .controller-stage { display: flex; flex-direction: column; gap: 14px; }
  .metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
  .metric-box { background: #0e131b; padding: 11px; border-radius: 10px; text-align: center; }
  .metric-val { font-size: 19px; font-weight: 800; color: var(--accent); }
  .metric-lbl { font-size: 11px; color: #8496ae; margin-top: 3px; }
  .buttons-grid { display: flex; flex-wrap: wrap; gap: 7px; }
  .gbtn { padding: 7px 12px; border-radius: 8px; background: #1c2433; border: 1px solid #2b374d; font-size: 12px; font-weight: 700; color: #8fa2bd; transition: 0.05s; }
  .gbtn.active { background: var(--accent); color: #000; border-color: #fff; box-shadow: 0 0 12px rgba(0,229,255,0.6); transform: scale(1.06); }
  .sticks-row { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
  .stick-box { background: #0e131b; padding: 12px; border-radius: 12px; display: flex; flex-direction: column; align-items: center; }
  .stick-circle { width: 104px; height: 104px; border-radius: 50%; border: 2px solid #2b374d; position: relative; margin: 8px 0; background: #121822; }
  .stick-dot { width: 20px; height: 20px; border-radius: 50%; background: var(--accent); position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); box-shadow: 0 0 8px var(--accent); }
  .trigger-bar { width: 100%; height: 10px; background: #1c2433; border-radius: 5px; overflow: hidden; margin-top: 6px; }
  .trigger-fill { height: 100%; width: 0%; background: var(--pink); transition: width 0.04s; }
</style>
</head>
<body>
  <div class="header">
    <div class="title">DARTPAD v${DartPadAppSettings.appVersion} RECEIVER (LAN + Wi-Fi + USB)</div>
    <div id="connBadge" class="badge">MENUNGGU HP (AUTO-PAIR / QR READY)...</div>
  </div>
  <div class="grid">
    <div class="card">
      <h2>Scan QR Kamera / PIN Pairing</h2>
      <div class="qr-box">
        $qrSvg
        <div class="pin-code">${payload.pin}</div>
      </div>
      <div style="font-size:11px;color:#8496ae;">Semua IP PC Aktif (LAN / Wi-Fi / USB):</div>
      <div class="ip-list">$ipsHtml</div>
      <div class="info-row"><span>UDP Port / HTTP Port</span><strong>${payload.port} / ${payload.httpPort}</strong></div>
      <div class="info-row"><span>Nama PC</span><strong>${payload.deviceName}</strong></div>
      <div class="uri-box" title="QR URI">${qrUri}</div>
      <button class="btn" onclick="testRumble()">Test Getar (Rumble) ke HP</button>
      <button id="fwBtn" class="btn warn" onclick="fixFirewall()">🛡️ Izinkan Firewall & Fix USB Tether LAN</button>
      <button id="installBtn" class="btn secondary" onclick="installShortcut()">📌 Pasang Shortcut Desktop & Auto-Start</button>
    </div>

    <div class="card controller-stage">
      <h2>Live Controller Button & Analog Tester</h2>
      <div class="metrics">
        <div class="metric-box"><div id="ppsVal" class="metric-val">0 Hz</div><div class="metric-lbl">Input Rate</div></div>
        <div class="metric-box"><div id="lossVal" class="metric-val">0.0%</div><div class="metric-lbl">Packet Loss</div></div>
        <div class="metric-box"><div id="seqVal" class="metric-val">#0</div><div class="metric-lbl">Sequence</div></div>
      </div>

      <div>
        <div style="font-size:12px;color:#8496ae;margin-bottom:6px;">TOMBOL AKTIF (Single, Combo (1) X→Y→A→A, & Volume Trigger):</div>
        <div id="btnContainer" class="buttons-grid"></div>
      </div>

      <div class="sticks-row">
        <div class="stick-box">
          <strong style="font-size:12px;">LEFT STICK + LT (Volume Up)</strong>
          <div class="stick-circle"><div id="lsDot" class="stick-dot"></div></div>
          <div id="lsText" style="font-size:11px;color:#8496ae;">X: 0.00 | Y: 0.00</div>
          <div class="trigger-bar"><div id="ltFill" class="trigger-fill"></div></div>
        </div>
        <div class="stick-box">
          <strong style="font-size:12px;">RIGHT STICK + RT (Volume Down)</strong>
          <div class="stick-circle"><div id="rsDot" class="stick-dot"></div></div>
          <div id="rsText" style="font-size:11px;color:#8496ae;">X: 0.00 | Y: 0.00</div>
          <div class="trigger-bar"><div id="rtFill" class="trigger-fill"></div></div>
        </div>
      </div>
    </div>
  </div>

<script>
const ALL_BUTTONS = [
  ['south','A / Cross'], ['east','B / Circle'], ['west','X / Square'], ['north','Y / Triangle'],
  ['leftShoulder','LB / L1'], ['rightShoulder','RB / R1'], ['leftTrigger','LT / L2'], ['rightTrigger','RT / R2'],
  ['dpadUp','Up'], ['dpadDown','Down'], ['dpadLeft','Left'], ['dpadRight','Right'],
  ['select','View / Create'], ['guide','Xbox / PS'], ['start','Menu / Options'], ['leftStick','L3'], ['rightStick','R3']
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
    badge.textContent = 'TERHUBUNG: ' + (data.clientDeviceName || 'Android') + ' (' + (data.clientAddress || '') + ')';
  } else {
    badge.className = 'badge';
    badge.textContent = 'MENUNGGU HP (AUTO-PAIR / QR READY)...';
  }
  document.getElementById('ppsVal').textContent = data.packetsPerSecond + ' Hz';
  document.getElementById('lossVal').textContent = data.packetLossPercent.toFixed(1) + '%';
  document.getElementById('seqVal').textContent = '#' + data.lastSequence;

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
  document.getElementById('lsText').textContent = 'X: ' + lx.toFixed(2) + ' | Y: ' + ly.toFixed(2);

  document.getElementById('rsDot').style.left = (50 + rx * 42) + '%';
  document.getElementById('rsDot').style.top = (50 - ry * 42) + '%';
  document.getElementById('rsText').textContent = 'X: ' + rx.toFixed(2) + ' | Y: ' + ry.toFixed(2);

  document.getElementById('ltFill').style.width = ((st.leftTrigger || 0) * 100) + '%';
  document.getElementById('rtFill').style.width = ((st.rightTrigger || 0) * 100) + '%';
};

function testRumble() {
  fetch('/api/rumble', { method: 'POST' });
}

async function fixFirewall() {
  const btn = document.getElementById('fwBtn');
  btn.textContent = 'Mengatur Firewall & Metric USB...';
  const res = await fetch('/api/fix-network', { method: 'POST' });
  const json = await res.json();
  btn.textContent = json.ok
    ? '✅ Firewall & USB Tether LAN Berhasil Diatur!'
    : '⚠️ Jalankan sebagai Administrator jika gagal';
}

async function installShortcut() {
  const btn = document.getElementById('installBtn');
  btn.textContent = 'Memasang Shortcut & Auto-Start...';
  const res = await fetch('/api/install-shortcut', { method: 'POST' });
  const json = await res.json();
  btn.textContent = json.ok
    ? '✅ Shortcut Desktop & Auto-Start Terpasang!'
    : '⚠️ Hanya tersedia di Windows';
}
</script>
</body>
</html>
''';
  }
}
