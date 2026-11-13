import 'dart:async';
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:dartpad_receiver/dartpad_receiver.dart';
import 'package:test/test.dart';

void main() {
  group('DartPadReceiverServer (Button Response, Latency, & Watchdog)', () {
    late SimulatedGamepadProvider simulatedGamepad;
    late DartPadReceiverServer server;
    late RawDatagramSocket clientSocket;

    late Completer<String> sessionCompleter;
    late StreamSubscription<RawSocketEvent> clientSub;

    setUp(() async {
      simulatedGamepad = SimulatedGamepadProvider(deviceType: ControllerType.xbox);
      server = DartPadReceiverServer(
        port: 0, // ephemeral port
        serverName: 'Test-PC',
        gamepadProvider: simulatedGamepad,
        watchdogTimeout: const Duration(milliseconds: 80),
        customPin: '123456',
      );
      await server.start(bindAddress: InternetAddress.loopbackIPv4);
      clientSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      sessionCompleter = Completer<String>();
      clientSub = clientSocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? dg;
        while ((dg = clientSocket.receive()) != null) {
          final ctrl = PacketCodec.decodeControl(dg!.data);
          if (ctrl.type == PacketType.accept && !sessionCompleter.isCompleted) {
            sessionCompleter.complete(ctrl.payload['sessionToken'] as String);
          }
        }
      });
    });

    tearDown(() async {
      await clientSub.cancel();
      clientSocket.close();
      await server.stop();
    });

    Future<String> pairClient() async {
      final connectBytes = PacketCodec.encodeControl(
        const ControlPacket(
          type: PacketType.connect,
          sequence: 1,
          timestampMs: 10,
          payload: {'pin': '123456', 'deviceName': 'TestPhone'},
        ),
      );
      clientSocket.send(connectBytes, InternetAddress.loopbackIPv4, server.boundPort);
      return sessionCompleter.future.timeout(const Duration(seconds: 2));
    }

    test('responds to single buttons, volume triggers, and combo buttons immediately', () async {
      final sessionToken = await pairClient();
      final sender = LowLatencyInputSender(
        socket: clientSocket,
        targetAddress: InternetAddress.loopbackIPv4,
        targetPort: server.boundPort,
        sessionToken: sessionToken,
      );

      // 1. Press A + B + RT
      sender.updateState(
        const ControllerState(
          buttons: {
            GamepadButton.south,
            GamepadButton.east,
            GamepadButton.rightTrigger,
          },
          leftStick: StickState(x: -0.5, y: 0.8),
          rightTrigger: 1.0,
        ),
        immediate: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(simulatedGamepad.lastState.isPressed(GamepadButton.south), isTrue);
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.east), isTrue);
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.rightTrigger), isTrue);
      expect(simulatedGamepad.lastState.rightTrigger, closeTo(1.0, 0.01));
      expect(simulatedGamepad.lastState.leftStick.x, closeTo(-0.5, 0.01));
      expect(simulatedGamepad.lastState.leftStick.y, closeTo(0.8, 0.01));
    });

    test('drops out-of-order UDP packets so stale buttons never overwrite newer state', () async {
      final sessionToken = await pairClient();
      final flag = PairingPayload.computeSessionFlag(sessionToken);

      // Send packet sequence #10 (Button A pressed)
      final pkt10 = PacketCodec.encodeInput(
        InputPacket(
          sequence: 10,
          timestampMs: 100,
          flags: flag,
          state: const ControllerState(buttons: {GamepadButton.south}),
        ),
      );
      clientSocket.send(pkt10, InternetAddress.loopbackIPv4, server.boundPort);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.south), isTrue);

      // Late arrival of older packet sequence #9 (all buttons released)
      final pkt9Stale = PacketCodec.encodeInput(
        InputPacket(
          sequence: 9,
          timestampMs: 90,
          flags: flag,
          state: ControllerState.neutral,
        ),
      );
      clientSocket.send(pkt9Stale, InternetAddress.loopbackIPv4, server.boundPort);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Receiver must have dropped #9 and kept Button A pressed!
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.south), isTrue);
      expect(server.sequenceTracker.droppedOutOfOrder, equals(1));
    });

    test('watchdog auto-releases all stuck buttons when connection drops', () async {
      final sessionToken = await pairClient();
      final sender = LowLatencyInputSender(
        socket: clientSocket,
        targetAddress: InternetAddress.loopbackIPv4,
        targetPort: server.boundPort,
        sessionToken: sessionToken,
      );

      // Hold down North (Y) and Left Trigger
      sender.updateState(
        const ControllerState(
          buttons: {GamepadButton.north, GamepadButton.leftTrigger},
          leftTrigger: 1.0,
        ),
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.north), isTrue);

      // Stop sending packets -> wait for 80ms watchdog timeout
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // All buttons and triggers must be auto-released to neutral!
      expect(simulatedGamepad.lastState.buttons, isEmpty);
      expect(simulatedGamepad.lastState.leftTrigger, equals(0.0));
      expect(simulatedGamepad.resetCount, greaterThanOrEqualTo(1));
    });

    test('MobileControllerEngine connects via QR Code URI and dispatches multi-touch, combo, and volume keys', () async {
      final qrPayload = server.buildPairingPayload('127.0.0.1');
      final qrAscii = QrPairingRenderer.renderTerminalQr(qrPayload);
      expect(qrAscii, isNotEmpty);

      final layout = ControllerLayout.defaultLandscape().addComboButton(
        id: 'combo_rage',
        label: 'RAGE (LB+RB)',
        comboActions: [
          GamepadButton.leftShoulder,
          GamepadButton.rightShoulder,
        ],
      );

      final reloadCompleter = Completer<RumbleEvent>();
      final mobileEngine = MobileControllerEngine(
        profile: ControllerProfile.xboxDefault(),
        layout: layout,
        updateRateHz: 120,
        onRumbleReceived: (rumble) {
          if (!reloadCompleter.isCompleted) {
            reloadCompleter.complete(rumble);
          }
        },
      );

      final connected = await mobileEngine.connectFromQrUri(
        qrPayload.toQrUriString(),
        clientDeviceName: 'Pixel-Test',
      );
      expect(connected, isTrue);

      // Simulate PC Game triggering heavy force-feedback rumble (80% large, 50% small)
      simulatedGamepad.triggerSimulatedRumble(
        const RumbleEvent(largeMotor: 0.80, smallMotor: 0.50, durationMs: 120),
      );

      // 1. Touch Combo Button ('combo_rage' -> LB + RB)
      mobileEngine.handleLayoutItemTouch('combo_rage', true);
      // 2. Simultaneously press physical Volume Up (LT = 1.0)
      final consumed = mobileEngine.handleHardwareKeyEvent(HardwareKey.volumeUp, true);
      expect(consumed, isTrue);
      // 3. Move Left Stick outside deadzone
      mobileEngine.handleJoystickMove(isLeftStick: true, rawX: 0.9, rawY: -0.5);

      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(simulatedGamepad.lastState.isPressed(GamepadButton.leftShoulder), isTrue);
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.rightShoulder), isTrue);
      expect(simulatedGamepad.lastState.isPressed(GamepadButton.leftTrigger), isTrue);
      expect(simulatedGamepad.lastState.leftTrigger, closeTo(1.0, 0.01));
      expect(simulatedGamepad.lastState.leftStick.x, greaterThan(0.5));

      // Verify Android received the Rumble (vibration) feedback from PC!
      final receivedRumble =
          await reloadCompleter.future.timeout(const Duration(seconds: 2));
      expect(receivedRumble.largeMotor, closeTo(0.80, 0.02));
      expect(receivedRumble.smallMotor, closeTo(0.50, 0.02));
      expect(receivedRumble.durationMs, equals(120));

      await mobileEngine.disconnect();
    });

    test('DartPadConfigStore persists and reloads JSON profiles, custom layouts, and settings', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartpad_config_test_');
      try {
        final store = DartPadConfigStore(tempDir);
        await store.ensureInitialized();

        final customLayout = ControllerLayout.defaultLandscape()
            .updateItem('btn_south', (item) => item.copyWith(x: 0.77, scale: 1.6))
            .addComboButton(
              id: 'combo_1',
              label: 'A+B',
              comboActions: [GamepadButton.south, GamepadButton.east],
            );

        await store.saveLayout(customLayout);
        final reloaded = await store.loadLayout(customLayout.id);
        final south = reloaded.items.firstWhere((e) => e.id == 'btn_south');
        final combo = reloaded.items.firstWhere((e) => e.id == 'combo_1');

        expect(south.x, closeTo(0.77, 1e-4));
        expect(south.scale, closeTo(1.6, 1e-4));
        expect(combo.actions, containsAll([GamepadButton.south, GamepadButton.east]));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
