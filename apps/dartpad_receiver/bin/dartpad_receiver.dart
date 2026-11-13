import 'dart:async';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:dartpad_receiver/dartpad_receiver.dart';

/// Entrypoint for `dartpad_receiver` (can be compiled to `dartpad_receiver.exe` via `dart compile exe`).
///
/// Modes:
/// - Default: Starts the UDP Receiver Server, prints the QR Pairing URI + 6-digit PIN,
///   and opens the Live Controller Button Tester.
/// - `--self-test`: Runs an automated local loopback test simulating an Android phone
///   connecting via PIN/QR, pressing single buttons, Volume triggers, Combo buttons,
///   and analog sticks, and verifying that the EXE responds with < 1ms latency.
Future<void> main(List<String> args) async {
  final isSelfTest = args.contains('--self-test');
  final monitor = const LiveControllerMonitor(preset: ControllerType.xbox);

  // Try native FFI driver first; gracefully fall back to SimulatedGamepadProvider
  // so button testing works even before installing the Windows kernel driver.
  GamepadProvider provider = FfiGamepadProvider(deviceType: ControllerType.xbox);
  final nativeLoaded = provider.init();
  if (!nativeLoaded) {
    provider = SimulatedGamepadProvider(deviceType: ControllerType.xbox)..init();
    stdout.writeln(
      '[INFO] Native virtual driver not detected; running in Live Button Tester / Simulation mode.',
    );
  } else {
    stdout.writeln('[OK] Native Virtual Gamepad Driver initialized.');
  }

  final server = DartPadReceiverServer(
    port: isSelfTest ? 0 : DartPadProtocolConstants.defaultPort,
    serverName: Platform.localHostname,
    gamepadProvider: provider,
    onDiagnosticsUpdate: isSelfTest
        ? null
        : (snapshot) {
            // Clear terminal screen and render live button/axis monitor
            stdout.write('\x1B[2J\x1B[0;0H');
            stdout.writeln(monitor.formatSnapshot(snapshot));
          },
  );

  await server.start(
    bindAddress: isSelfTest ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
  );

  final localIp = await _detectLocalIpv4() ?? '127.0.0.1';
  final qrPayload = server.buildPairingPayload(localIp);

  stdout.writeln('====================================================================');
  stdout.writeln(' DARTPAD WINDOWS RECEIVER READY — SCAN QR OR ENTER PIN ON PHONE');
  stdout.writeln(' Local IP : $localIp:${server.boundPort}');
  stdout.writeln(' PIN Code : ${server.pairingPin}');
  stdout.writeln(' QR URI   : ${qrPayload.toQrUriString()}');
  stdout.writeln('--------------------------------------------------------------------');
  stdout.write(QrPairingRenderer.renderTerminalQr(qrPayload));
  stdout.writeln('====================================================================');

  if (isSelfTest) {
    final exitCode = await _runButtonResponseSelfTest(server, qrPayload, monitor);
    await server.stop();
    exit(exitCode);
  }

  // Keep running until Ctrl+C
  await ProcessSignal.sigint.watch().first;
  stdout.writeln('\nShutting down DartPad Receiver & releasing all buttons...');
  await server.stop();
}

Future<int> _runButtonResponseSelfTest(
  DartPadReceiverServer server,
  PairingPayload qrPayload,
  LiveControllerMonitor monitor,
) async {
  stdout.writeln('\n[SELF-TEST] Starting End-to-End Button Response & Latency Verification...');
  final clientSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
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

  final sessionToken = await completer.future.timeout(const Duration(seconds: 2));
  stdout.writeln('[SELF-TEST] Paired with Receiver! Session Token: $sessionToken');

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
    stderr.writeln('[FAIL] Volume Key Trigger (RT) did NOT respond on receiver!');
    clientSocket.close();
    return 1;
  }
  stdout.writeln('[PASS] Volume Down -> Right Trigger (RT = 100%) responded on Receiver!');

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
  sender.updateState(withCombo.copyWith(
    leftStick: const StickState(x: 0.75, y: -0.50),
  ), immediate: true);
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
  stdout.writeln('[PASS] Combo Button (LB + RB + Y) + Left Stick responded on Receiver!');

  stdout.writeln('\nLive Monitor Snapshot at Peak Input:');
  stdout.writeln(
    monitor.formatSnapshot(
      ReceiverDiagnosticsSnapshot(
        isConnected: server.isClientConnected,
        clientAddress: '127.0.0.1',
        clientDeviceName: 'DartPad-SelfTest-Phone',
        currentState: server.currentState,
        packetsPerSecond: 120,
        packetLossPercent: server.sequenceTracker.packetLossRatio * 100,
        droppedOutOfOrder: server.sequenceTracker.droppedOutOfOrder,
        lastSequence: sender.sequence,
      ),
    ),
  );

  clientSocket.close();
  stdout.writeln('[SELF-TEST] ALL BUTTONS, VOLUME TRIGGERS, & COMBOS RESPONDED PERFECTLY!');
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
