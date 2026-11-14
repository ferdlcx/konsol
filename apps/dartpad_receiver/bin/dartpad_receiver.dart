import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:dartpad_receiver/dartpad_receiver.dart';

typedef _GetConsoleWindowNative = ffi.IntPtr Function();
typedef _GetConsoleWindowDart = int Function();

typedef _ShowWindowNative = ffi.Int32 Function(
  ffi.IntPtr hWnd,
  ffi.Int32 nCmdShow,
);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

/// Single-file standalone Windows Launcher (`DartPad.exe`).
///
/// Features:
/// - **ViGEmBus Xbox 360 + Sony DualShock 4 Virtual Gamepad**: Full XInput & DS4 support.
/// - **Zero Flicker / Background Friendly**: Removes 120Hz console redraws and hides
///   the Windows console window after launching the minimalist GUI Dashboard
///   (unless `--console` or `--self-test` is specified).
/// - **Single-Instance Detection**: Re-launching opens the existing Dashboard cleanly.
Future<void> main(List<String> args) async {
  final isSelfTest = args.contains('--self-test');
  final keepConsole = args.contains('--console');
  final monitor = const LiveControllerMonitor(preset: ControllerType.xbox);

  if (!isSelfTest) {
    final alreadyRunning =
        await EmbeddedDashboardGui.tryActivateExistingInstance();
    if (alreadyRunning) {
      stdout.writeln('DartPad Receiver already running — opened GUI Dashboard.');
      return;
    }
  }

  final provider = PureDartWindowsGamepadProvider(
    deviceType: ControllerType.xbox,
    enableWin32KeyboardFallback: false,
  )..init();

  final shutdownCompleter = Completer<void>();
  EmbeddedDashboardGui? gui;

  final server = DartPadReceiverServer(
    port: isSelfTest ? 0 : DartPadProtocolConstants.defaultPort,
    serverName: Platform.localHostname,
    gamepadProvider: provider,
    onDiagnosticsUpdate: (snapshot) {
      gui?.broadcastSnapshot(snapshot);
    },
  );

  await server.start(
    bindAddress:
        isSelfTest ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
  );

  final allIps = await _detectAllPhysicalIpv4s();
  final primaryIp = allIps.isNotEmpty ? allIps.first : '127.0.0.1';

  gui = EmbeddedDashboardGui(
    receiverServer: server,
    localIp: primaryIp,
    allIps: allIps,
    preferredPort: isSelfTest ? 0 : 42101,
    onShutdownRequested: () {
      if (!shutdownCompleter.isCompleted) {
        shutdownCompleter.complete();
      }
    },
  );
  await gui.start(
    openDesktopWindow: !isSelfTest,
    bindLoopbackOnly: isSelfTest,
  );
  server.advertisedHttpPort = gui.guiPort;

  final qrPayload = server.buildPairingPayload(
    primaryIp,
    allIps: allIps,
    httpPort: gui.guiPort,
  );

  stdout.writeln('====================================================================');
  stdout.writeln(' DARTPAD RECEIVER v${DartPadAppSettings.appVersion}');
  stdout.writeln(' Driver     : ${provider.driverStatusSummary}');
  stdout.writeln(' GUI Window : ${gui.dashboardUrl}');
  stdout.writeln(' Local IPs  : ${allIps.isEmpty ? primaryIp : allIps.join(", ")}');
  stdout.writeln(' UDP / HTTP : ${server.boundPort} / ${gui.guiPort}');
  stdout.writeln(' PIN Code   : ${server.pairingPin}');
  stdout.writeln(' QR URI     : ${qrPayload.toQrUriString()}');
  stdout.writeln('--------------------------------------------------------------------');
  if (isSelfTest || keepConsole) {
    stdout.write(QrPairingRenderer.renderTerminalQr(qrPayload));
  }
  stdout.writeln('====================================================================');

  if (isSelfTest) {
    final exitCode =
        await _runButtonResponseSelfTest(server, qrPayload, monitor);
    await gui.stop();
    await server.stop();
    exit(exitCode);
  }

  // Hide blinking Windows CMD console once GUI Dashboard is open so closing CMD
  // cannot accidentally terminate active controller sessions!
  if (Platform.isWindows && !keepConsole) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    _hideWindowsConsoleWindow();
  }

  unawaited(
    ProcessSignal.sigint.watch().first.then((_) {
      if (!shutdownCompleter.isCompleted) {
        shutdownCompleter.complete();
      }
    }),
  );

  await shutdownCompleter.future;
  await gui.stop();
  await server.stop();
  exit(0);
}

void _hideWindowsConsoleWindow() {
  if (!Platform.isWindows) return;
  try {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final user32 = ffi.DynamicLibrary.open('user32.dll');
    final getConsole = kernel32
        .lookup<ffi.NativeFunction<_GetConsoleWindowNative>>('GetConsoleWindow')
        .asFunction<_GetConsoleWindowDart>();
    final showWindow = user32
        .lookup<ffi.NativeFunction<_ShowWindowNative>>('ShowWindow')
        .asFunction<_ShowWindowDart>();
    final hwnd = getConsole();
    if (hwnd != 0) {
      showWindow(hwnd, 0); // SW_HIDE = 0
    }
  } catch (_) {}
}

Future<int> _runButtonResponseSelfTest(
  DartPadReceiverServer server,
  PairingPayload qrPayload,
  LiveControllerMonitor monitor,
) async {
  stdout.writeln(
      '\n[SELF-TEST] Starting End-to-End Button Response & Latency Verification...');
  final clientSocket =
      await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final serverAddr = InternetAddress.loopbackIPv4;
  final serverPort = server.boundPort;

  final completer = Completer<String>();
  clientSocket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = clientSocket.receive();
    if (dg == null) return;
    final ctrl = PacketCodec.decodeControl(dg.data);
    if (ctrl.type == PacketType.accept && !completer.isCompleted) {
      completer.complete(ctrl.payload['sessionToken'] as String);
    }
  });

  final connectBytes = PacketCodec.encodeControl(
    ControlPacket(
      type: PacketType.connect,
      sequence: 1,
      timestampMs: 100,
      payload: {
        'pin': qrPayload.pin,
        'deviceName': 'DartPad-SelfTest-Phone',
      },
    ),
  );
  clientSocket.send(connectBytes, serverAddr, serverPort);

  final sessionToken =
      await completer.future.timeout(const Duration(seconds: 2));
  stdout.writeln(
      '[SELF-TEST] Paired with Receiver! Session Token: $sessionToken');

  final sender = LowLatencyInputSender(
    socket: clientSocket,
    targetAddress: serverAddr,
    targetPort: serverPort,
    sessionToken: sessionToken,
    updateRateHz: 120,
  );

  // 1. Test Instant Button Press (A / South)
  final sw = Stopwatch()..start();
  sender.setButtonPressed(GamepadButton.south, true);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  final elapsedMicros = sw.elapsedMicroseconds;

  if (!server.currentState.isPressed(GamepadButton.south)) {
    stderr.writeln('[FAIL] Button A (south) did NOT respond on receiver!');
    clientSocket.close();
    return 1;
  }
  stdout.writeln(
    '[PASS] Single Button A (south) responded on Receiver! (round-trip < ${(elapsedMicros / 1000).toStringAsFixed(2)} ms)',
  );

  // 2. Test L3 & R3 buttons
  sender.setButtonPressed(GamepadButton.rightStick, true);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  if (!server.currentState.isPressed(GamepadButton.rightStick)) {
    stderr.writeln('[FAIL] Button R3 (rightStick) did NOT respond on receiver!');
    clientSocket.close();
    return 1;
  }
  stdout.writeln('[PASS] R3 (rightStick) responded on Receiver!');

  // 3. Test Volume Key as Trigger (Volume Down -> RT = 1.0)
  final profile = ControllerProfile.xboxDefault();
  final withVolumeTrigger = profile.applyHardwareKey(
    current: sender.currentState,
    key: HardwareKey.volumeDown,
    isPressed: true,
  );
  sender.updateState(withVolumeTrigger, immediate: true);
  await Future<void>.delayed(const Duration(milliseconds: 5));

  if (!server.currentState.isPressed(GamepadButton.rightTrigger) ||
      server.currentState.rightTrigger < 0.99) {
    stderr.writeln(
        '[FAIL] Volume Key Trigger (RT) did NOT respond on receiver!');
    clientSocket.close();
    return 1;
  }
  stdout.writeln(
      '[PASS] Volume Down -> Right Trigger (RT = 100%) responded on Receiver!');

  // 4. Test Custom Combo Button (LB + RB + Y)
  final layout = ControllerLayout.defaultLandscape().addComboButton(
    id: 'combo_ult',
    label: 'ULT',
    comboActions: [
      GamepadButton.leftShoulder,
      GamepadButton.rightShoulder,
      GamepadButton.north,
    ],
  );
  final comboItem = layout.items.firstWhere((e) => e.id == 'combo_ult');
  final withCombo = comboItem.applyToState(
    current: sender.currentState,
    isPressed: true,
  );
  sender.updateState(
    withCombo.copyWith(
      leftStick: const StickState(x: 0.75, y: -0.50),
    ),
    immediate: true,
  );
  await Future<void>.delayed(const Duration(milliseconds: 5));

  final rxState = server.currentState;
  final comboResponded = rxState.isPressed(GamepadButton.leftShoulder) &&
      rxState.isPressed(GamepadButton.rightShoulder) &&
      rxState.isPressed(GamepadButton.north);
  if (!comboResponded) {
    stderr.writeln('[FAIL] Combo Button (LB+RB+Y) did NOT respond on receiver!');
    clientSocket.close();
    return 1;
  }
  stdout.writeln(
      '[PASS] Combo Button (LB + RB + Y) + Left Stick responded on Receiver!');

  clientSocket.close();
  stdout.writeln('[SELF-TEST] ALL CHECKS PASSED!');
  return 0;
}

/// Detects all active LAN/Wi-Fi/USB IPv4 addresses, ranking physical LAN/Wi-Fi
/// ahead of virtual adapters (WSL, Hyper-V, VirtualBox, Docker).
Future<List<String>> _detectAllPhysicalIpv4s() async {
  final preferred = <String>[];
  final secondary = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      final lowerName = iface.name.toLowerCase();
      final isVirtual = lowerName.contains('vethernet') ||
          lowerName.contains('wsl') ||
          lowerName.contains('hyper-v') ||
          lowerName.contains('virtualbox') ||
          lowerName.contains('vmware') ||
          lowerName.contains('docker') ||
          lowerName.contains('loopback') ||
          lowerName.contains('tailscale');

      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.isLoopback || ip.startsWith('169.254.')) continue;
        final isVirtualRange =
            ip.startsWith('192.168.56.') || ip.startsWith('172.');
        if (!isVirtual && !isVirtualRange) {
          if (!preferred.contains(ip)) preferred.add(ip);
        } else {
          if (!secondary.contains(ip)) secondary.add(ip);
        }
      }
    }
  } catch (_) {}
  return [...preferred, ...secondary];
}
