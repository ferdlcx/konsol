import 'dart:async';
import 'dart:convert';
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

    test('Zero-touch Auto-Discovery & Auto-Pair (Wi-Fi/USB) + Sequential Combo (1) X -> Y -> A -> A', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartpad_autopair_test_');
      try {
        final store = DartPadConfigStore(tempDir);
        await store.ensureInitialized();

        final observedButtonSequence = <GamepadButton>[];
        GamepadButton? lastRecorded;
        final trackerGamepad = SimulatedGamepadProvider(
          onStateChanged: (st) {
            if (st.buttons.length == 1) {
              final b = st.buttons.first;
              if (b != lastRecorded) {
                observedButtonSequence.add(b);
                lastRecorded = b;
              }
            } else if (st.buttons.isEmpty) {
              lastRecorded = null;
            }
          },
        );

        final autoServer = DartPadReceiverServer(
          port: 0,
          serverName: 'AutoPair-PC',
          gamepadProvider: trackerGamepad,
          customPin: '654321',
        );
        await autoServer.start(bindAddress: InternetAddress.loopbackIPv4);

        final mobileEngine = MobileControllerEngine(
          configStore: store,
          layout: ControllerLayout.defaultLandscape(),
        );

        // 1. Auto-discover & Auto-pair without typing IP or PIN!
        final paired = await mobileEngine.discoverAndAutoConnect(
          port: autoServer.boundPort,
          timeout: const Duration(seconds: 2),
        );
        expect(paired, isTrue);

        // Verify paired credentials were saved to disk for reboot persistence
        final savedSettings = await store.loadSettings();
        expect(savedSettings.lastPairedPin, equals('654321'));
        expect(savedSettings.lastConnectedPort, equals(autoServer.boundPort));

        // 2. Trigger built-in Combo (1): Sequential Macro [X -> Y -> A -> A]
        // Speed up stepDelayMs to 30ms for fast unit test verification
        mobileEngine.setLayout(
          mobileEngine.layout.updateItem(
            'combo_1',
            (item) => item.copyWith(stepDelayMs: 35),
          ),
        );
        mobileEngine.handleLayoutItemTouch('combo_1', true);

        await Future<void>.delayed(const Duration(milliseconds: 220));

        expect(
          observedButtonSequence,
          equals([
            GamepadButton.west, // X
            GamepadButton.north, // Y
            GamepadButton.south, // A
            GamepadButton.south, // A
          ]),
        );

        await mobileEngine.disconnect();
        await autoServer.stop();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Multi-IP PairingPayload connects via fallback candidate IP when primary IP is unreachable', () async {
      final server = DartPadReceiverServer(
        port: 0,
        serverName: 'DualNic-PC',
        gamepadProvider: SimulatedGamepadProvider(),
        customPin: '998877',
      );
      await server.start(bindAddress: InternetAddress.loopbackIPv4);

      final engine = MobileControllerEngine();
      try {
        // Primary IP is a non-routable / dead virtual adapter IP, second IP is live 127.0.0.1
        final payload = PairingPayload(
          ip: '192.0.2.55',
          allIps: const ['192.0.2.55', '127.0.0.1'],
          port: server.boundPort,
          pin: '998877',
          deviceName: 'DualNic-PC',
        );

        final ok = await engine.connectWithPayload(
          payload,
          timeout: const Duration(seconds: 2),
        );
        expect(ok, isTrue);
        expect(engine.connectedServerIp, equals('127.0.0.1'));
        expect(engine.connectedServerName, equals('DualNic-PC'));
      } finally {
        await engine.disconnect();
        await server.stop();
      }
    });

    test('EmbeddedDashboardGui & GamepadProvider support runtime Xbox 360 <-> PlayStation DS4 switching', () async {
      final simGamepad = SimulatedGamepadProvider(deviceType: ControllerType.xbox);
      final modeServer = DartPadReceiverServer(
        port: 0,
        serverName: 'ModeSwitch-PC',
        gamepadProvider: simGamepad,
        customPin: '112233',
      );
      await modeServer.start(bindAddress: InternetAddress.loopbackIPv4);

      final gui = EmbeddedDashboardGui(
        receiverServer: modeServer,
        localIp: '127.0.0.1',
        preferredPort: 0,
      );
      await gui.start(openDesktopWindow: false, bindLoopbackOnly: true);

      final httpClient = HttpClient();
      try {
        expect(simGamepad.deviceType, equals(ControllerType.xbox));

        final switchReq = await httpClient.postUrl(
          Uri.parse('http://127.0.0.1:${gui.guiPort}/api/switch-mode'),
        );
        switchReq.headers.contentType = ContentType.json;
        switchReq.write(jsonEncode({'type': 'playstation'}));
        final switchResp = await switchReq.close();
        final switchJson = jsonDecode(
          await utf8.decoder.bind(switchResp).join(),
        ) as Map<String, dynamic>;

        expect(switchJson['ok'], isTrue);
        expect(switchJson['deviceType'], equals('playstation'));
        expect(simGamepad.deviceType, equals(ControllerType.playstation));

        final infoReq = await httpClient.getUrl(
          Uri.parse('http://127.0.0.1:${gui.guiPort}/api/info'),
        );
        final infoResp = await infoReq.close();
        final infoJson = jsonDecode(
          await utf8.decoder.bind(infoResp).join(),
        ) as Map<String, dynamic>;
        expect(infoJson['deviceType'], equals('playstation'));
        expect(infoJson['version'], equals(DartPadAppSettings.appVersion));
      } finally {
        httpClient.close(force: true);
        await gui.stop();
        await modeServer.stop();
      }
    });

    test('PureDartWindowsGamepadProvider.isValidPeExportDll rejects 0-export DLLs and accepts valid PE32+ export tables', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartpad_pe_test_');
      try {
        // Construct minimal 512-byte PE32+ image with zero Export Directory (broken v0.3.0 DLL)
        final stubBytes = List<int>.filled(512, 0);
        stubBytes[0] = 0x4D; // 'M'
        stubBytes[1] = 0x5A; // 'Z'
        stubBytes[0x3C] = 0x80; // e_lfanew = 0x80
        stubBytes[0x80] = 0x50; // 'P'
        stubBytes[0x81] = 0x45; // 'E'
        // Optional header at 0x80 + 24 = 0x98, Magic = 0x020B (PE32+)
        stubBytes[0x98] = 0x0B;
        stubBytes[0x99] = 0x02;

        final brokenDll = File('${tempDir.path}/broken_ViGEmClient.dll')
          ..writeAsBytesSync(stubBytes);
        expect(PureDartWindowsGamepadProvider.isValidPeExportDll(brokenDll), isFalse);

        // Set DataDirectory[0] (offset 0x98 + 112 = 0x108): RVA = 0x2000, Size = 0x150
        stubBytes[0x108] = 0x00;
        stubBytes[0x109] = 0x20;
        stubBytes[0x10C] = 0x50;
        stubBytes[0x10D] = 0x01;

        final validDll = File('${tempDir.path}/valid_ViGEmClient.dll')
          ..writeAsBytesSync(stubBytes);
        expect(PureDartWindowsGamepadProvider.isValidPeExportDll(validDll), isTrue);

        expect(
          PureDartWindowsGamepadProvider.formatVigemError(0xE0000001),
          contains('ViGEmBus'),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
