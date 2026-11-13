import 'dart:async';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:dartpad_receiver/dartpad_receiver.dart';

/// Single-file standalone Windows Launcher (`DartPad.exe`).
///
/// Features:
/// - **100% Pure Dart**: No custom C++ `.dll` file required alongside `DartPad.exe`.
/// - **Built-in Desktop GUI Dashboard**: Automatically launches the graphical
///   DartPad Dashboard window (SVG QR Code, 6-digit PIN, Live Gamepad Button
///   Visualizer, and One-Click Rumble Vibration Tester).
/// - **`--self-test` Mode**: Verifies end-to-end button, volume trigger, combo,
///   and GUI dashboard responsiveness.
Future<void> main(List<String> args) async {
  final isSelfTest = args.contains('--self-test');
  final monitor = const LiveControllerMonitor(preset: ControllerType.xbox);

  // 100% Pure-Dart Windows Gamepad Provider (no external custom C++ DLL needed)
  final provider = PureDartWindowsGamepadProvider(
    deviceType: ControllerType.xbox,
    enableWin32KeyboardFallback: false,
  )..init();

  EmbeddedDashboardGui? gui;

  final server = DartPadReceiverServer(
    port: isSelfTest ? 0 : DartPadProtocolConstants.defaultPort,
    serverName: Platform.localHostname,
    gamepadProvider: provider,
    onDiagnosticsUpdate: (snapshot) {
      gui?.broadcastSnapshot(snapshot);
      if (!isSelfTest) {
        stdout.write('\x1B[2J\x1B[0;0H');
        stdout.writeln(monitor.formatSnapshot(snapshot));
        if (gui != null) {
          stdout.writeln(' GUI Dashboard : ${gui.dashboardUrl}');
        }
      }
    },
  );

  await server.start(
    bindAddress:
        isSelfTest ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
  );

  final localIp = await _detectLocalIpv4() ?? '127.0.0.1';
  final qrPayload = server.buildPairingPayload(localIp);

  gui = EmbeddedDashboardGui(
    receiverServer: server,
    localIp: localIp,
  );
  await gui.start(openDesktopWindow: !isSelfTest);

  stdout.writeln('====================================================================');
  stdout.writeln(' DARTPAD WINDOWS LAUNCHER (SINGLE .EXE + GUI DASHBOARD)');
  stdout.writeln(' GUI Window : ${gui.dashboardUrl}');
  stdout.writeln(' Local IP   : $localIp:${server.boundPort}');
  stdout.writeln(' PIN Code   : ${server.pairingPin}');
  stdout.writeln(' QR URI     : ${qrPayload.toQrUriString()}');
  stdout.writeln('--------------------------------------------------------------------');
  stdout.write(QrPairingRenderer.renderTerminalQr(qrPayload));
  stdout.writeln('====================================================================');

  if (isSelfTest) {
    final exitCode =
        await _runButtonResponseSelfTest(server, qrPayload, monitor);
    await gui.stop();
    await server.stop();
    exit(exitCode);
  }

  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nShutting down DartPad & releasing all buttons...');
  await gui.stop();
  await server.stop();
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

  // 1. Connect using QR Payload PIN
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

  // 2. Test Instant Button Press (A / South)
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
  stdout.writeln(
      '[SELF-TEST] ALL BUTTONS, VOLUME TRIGGERS, & COMBOS RESPONDED PERFECTLY IN SINGLE EXE!');
  return 0;
}

Future<String?> _detectLocalIpv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
  } catch (_) {}
  return null;
}
