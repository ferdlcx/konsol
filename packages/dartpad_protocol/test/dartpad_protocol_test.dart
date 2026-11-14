import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('GamepadButton & Bitmask', () {
    test('encodes and decodes button bitmasks accurately', () {
      final buttons = {
        GamepadButton.south,
        GamepadButton.north,
        GamepadButton.rightShoulder,
        GamepadButton.dpadLeft,
        GamepadButton.rightStick,
      };

      final mask = GamepadButton.encodeBitmask(buttons);
      final decoded = GamepadButton.decodeBitmask(mask);

      expect(decoded, equals(buttons));
    });

    test('maps Xbox and PlayStation labels from unified internal enum', () {
      expect(ControllerType.xbox.labelFor(GamepadButton.south), equals('A'));
      expect(ControllerType.playstation.labelFor(GamepadButton.south), equals('Cross'));
      expect(ControllerType.xbox.labelFor(GamepadButton.leftShoulder), equals('LB'));
      expect(ControllerType.playstation.labelFor(GamepadButton.leftShoulder), equals('L1'));
    });
  });

  group('StickState Normalizer', () {
    test('zeroes out input within radial deadzone', () {
      const stick = StickState(x: 0.05, y: -0.04); // magnitude ~0.064 < 0.08
      expect(stick.normalize(deadzone: 0.08), equals(StickState.zero));
    });

    test('clamps diagonal movement to circular boundary (magnitude <= 1.0)', () {
      const stick = StickState(x: 1.0, y: 1.0); // magnitude ~1.414
      final normalized = stick.normalize(deadzone: 0.08, sensitivity: 1.0);

      expect(normalized.magnitude, closeTo(1.0, 1e-4));
      expect(normalized.x, closeTo(0.7071, 1e-3));
      expect(normalized.y, closeTo(0.7071, 1e-3));
    });
  });

  group('PacketCodec (28-byte Binary INPUT & Control Packets)', () {
    test('encodes and decodes 28-byte INPUT packet losslessly within quantization', () {
      final originalState = ControllerState(
        buttons: {
          GamepadButton.south,
          GamepadButton.east,
          GamepadButton.leftShoulder,
          GamepadButton.start,
        },
        leftStick: const StickState(x: 0.45, y: -0.75),
        rightStick: const StickState(x: -1.0, y: 1.0),
        leftTrigger: 0.0,
        rightTrigger: 0.8,
      );

      final packet = InputPacket(
        sequence: 1042,
        timestampMs: 98765432,
        state: originalState,
        flags: 0xABCD,
      );

      final bytes = PacketCodec.encodeInput(packet);
      expect(bytes.length, equals(28));
      expect(PacketCodec.peekPacketType(bytes), equals(PacketType.input));

      final decoded = PacketCodec.decodeInput(bytes);
      expect(decoded.sequence, equals(1042));
      expect(decoded.timestampMs, equals(98765432));
      expect(decoded.flags, equals(0xABCD));
      expect(decoded.state.buttons, equals(originalState.buttons));
      expect(decoded.state.leftStick.x, closeTo(0.45, 0.001));
      expect(decoded.state.leftStick.y, closeTo(-0.75, 0.001));
      expect(decoded.state.rightStick.x, closeTo(-1.0, 0.001));
      expect(decoded.state.rightStick.y, closeTo(1.0, 0.001));
      expect(decoded.state.leftTrigger, closeTo(0.0, 0.005));
      expect(decoded.state.rightTrigger, closeTo(0.8, 0.005));
    });

    test('rejects invalid packet size or wrong magic bytes', () {
      expect(
        () => PacketCodec.decodeInput(Uint8List(16)),
        throwsFormatException,
      );

      final corrupted = Uint8List(28);
      corrupted[0] = 0x00;
      corrupted[1] = 0x00;
      expect(
        () => PacketCodec.decodeInput(corrupted),
        throwsFormatException,
      );
    });

    test('encodes and decodes ControlPacket handshake messages', () {
      const control = ControlPacket(
        type: PacketType.connect,
        sequence: 1,
        timestampMs: 12345,
        payload: {
          'pin': '482910',
          'deviceName': 'Pixel 8 Pro',
        },
      );

      final encoded = PacketCodec.encodeControl(control);
      expect(PacketCodec.peekPacketType(encoded), equals(PacketType.connect));

      final decoded = PacketCodec.decodeControl(encoded);
      expect(decoded.type, equals(PacketType.connect));
      expect(decoded.sequence, equals(1));
      expect(decoded.timestampMs, equals(12345));
      expect(decoded.payload['pin'], equals('482910'));
      expect(decoded.payload['deviceName'], equals('Pixel 8 Pro'));
    });
  });

  group('PairingPayload (QR Code URI & Session Flag)', () {
    test('serializes and parses QR Code pairing URI', () {
      const payload = PairingPayload(
        ip: '192.168.1.25',
        port: 42100,
        pin: '839201',
        deviceName: 'FERD-PC',
      );

      final qrString = payload.toQrUriString();
      expect(qrString, startsWith('dartpad://connect?'));

      final parsed = PairingPayload.fromQrUriString(qrString);
      expect(parsed.ip, equals('192.168.1.25'));
      expect(parsed.port, equals(42100));
      expect(parsed.pin, equals('839201'));
      expect(parsed.deviceName, equals('FERD-PC'));
    });

    test('computes deterministic 16-bit session flag', () {
      final flag1 = PairingPayload.computeSessionFlag('session-abc-123');
      final flag2 = PairingPayload.computeSessionFlag('session-abc-123');
      final flagOther = PairingPayload.computeSessionFlag('session-xyz-999');

      expect(flag1, equals(flag2));
      expect(flag1, isNot(equals(flagOther)));
      expect(flag1 & 0xFFFF, equals(flag1));
    });
  });

  group('HardwareKey (Volume Keys as Triggers)', () {
    test('maps Volume Up/Down to LT/RT and updates trigger axes', () {
      final profile = ControllerProfile.xboxDefault();
      var state = ControllerState.neutral;

      // Press Volume Up (default -> leftTrigger)
      state = profile.applyHardwareKey(
        current: state,
        key: HardwareKey.volumeUp,
        isPressed: true,
      );
      expect(state.isPressed(GamepadButton.leftTrigger), isTrue);
      expect(state.leftTrigger, equals(1.0));
      expect(state.rightTrigger, equals(0.0));

      // Press Volume Down simultaneously (default -> rightTrigger)
      state = profile.applyHardwareKey(
        current: state,
        key: HardwareKey.volumeDown,
        isPressed: true,
      );
      expect(state.isPressed(GamepadButton.rightTrigger), isTrue);
      expect(state.leftTrigger, equals(1.0));
      expect(state.rightTrigger, equals(1.0));

      // Release Volume Up
      state = profile.applyHardwareKey(
        current: state,
        key: HardwareKey.volumeUp,
        isPressed: false,
      );
      expect(state.isPressed(GamepadButton.leftTrigger), isFalse);
      expect(state.leftTrigger, equals(0.0));
      expect(state.rightTrigger, equals(1.0));
    });
  });

  group('ControllerLayout (Position, Resize, & Combo Buttons)', () {
    test('moves, resizes, and serializes button layout items', () {
      var layout = ControllerLayout.defaultLandscape(preset: ControllerType.xbox);

      // Move and resize button 'A' (btn_south)
      layout = layout.updateItem(
        'btn_south',
        (item) => item.copyWith(x: 0.75, y: 0.65, scale: 1.45, opacity: 0.9),
      );

      final southBtn = layout.items.firstWhere((e) => e.id == 'btn_south');
      expect(southBtn.x, closeTo(0.75, 1e-4));
      expect(southBtn.y, closeTo(0.65, 1e-4));
      expect(southBtn.scale, closeTo(1.45, 1e-4));

      // JSON round-trip
      final decoded = ControllerLayout.fromJson(layout.toJson());
      final decodedSouth = decoded.items.firstWhere((e) => e.id == 'btn_south');
      expect(decodedSouth.x, closeTo(0.75, 1e-4));
      expect(decodedSouth.scale, closeTo(1.45, 1e-4));
    });

    test('creates and triggers multi-button Combo (e.g., LB + RB + Y)', () {
      var layout = ControllerLayout.defaultLandscape();
      layout = layout.addComboButton(
        id: 'combo_ult',
        label: 'ULT (LB+RB)',
        comboActions: [
          GamepadButton.leftShoulder,
          GamepadButton.rightShoulder,
          GamepadButton.rightTrigger,
        ],
        x: 0.65,
        y: 0.28,
        scale: 1.2,
      );

      final comboBtn = layout.items.firstWhere((e) => e.id == 'combo_ult');
      expect(comboBtn.isCombo, isTrue);

      // Press Combo Button -> all 3 buttons + RT analog trigger activate together
      var state = ControllerState.neutral;
      state = comboBtn.applyToState(current: state, isPressed: true);
      expect(state.isPressed(GamepadButton.leftShoulder), isTrue);
      expect(state.isPressed(GamepadButton.rightShoulder), isTrue);
      expect(state.isPressed(GamepadButton.rightTrigger), isTrue);
      expect(state.rightTrigger, equals(1.0));

      // Release Combo Button -> all 3 buttons + RT release cleanly
      state = comboBtn.applyToState(current: state, isPressed: false);
      expect(state.buttons, isEmpty);
      expect(state.rightTrigger, equals(0.0));
    });

    test('multi-IP PairingPayload serializes ips & httpPort cleanly', () {
      const payload = PairingPayload(
        ip: '192.168.1.50',
        allIps: ['192.168.1.50', '192.168.42.10', '192.168.1.50'],
        port: 42100,
        httpPort: 42101,
        pin: '123456',
        deviceName: 'MyPC',
      );
      expect(payload.candidateIps, equals(['192.168.1.50', '192.168.42.10']));

      final parsed = PairingPayload.fromQrUriString(payload.toQrUriString());
      expect(parsed.ip, equals('192.168.1.50'));
      expect(parsed.httpPort, equals(42101));
      expect(parsed.candidateIps, equals(['192.168.1.50', '192.168.42.10']));
    });

    test('xbox_authentic_v2 layout enlarges LS, XYAB, and bumpers with zero element overlap across viewports', () {
      final layout = ControllerLayout.defaultLandscape(preset: ControllerType.xbox);
      expect(layout.id, equals('xbox_authentic_v2'));

      final ls = layout.items.firstWhere((e) => e.id == 'left_stick');
      final aBtn = layout.items.firstWhere((e) => e.id == 'btn_south');
      final ltBtn = layout.items.firstWhere((e) => e.id == 'btn_lt');
      expect(ls.scale, greaterThanOrEqualTo(1.4));
      expect(aBtn.scale, greaterThanOrEqualTo(1.6));
      expect(ltBtn.scale, greaterThanOrEqualTo(1.4));

      // Verify zero pairwise overlap on typical Android landscape viewports
      for (final viewport in const [
        (w: 680.0, h: 360.0),
        (w: 800.0, h: 360.0),
        (w: 915.0, h: 412.0),
      ]) {
        final w = viewport.w;
        final h = viewport.h;
        final shortest = math.min(w, h);
        final rects = <({String id, double l, double t, double r, double b})>[];

        for (final item in layout.items) {
          final isBumper = item.id == 'btn_lt' ||
              item.id == 'btn_lb' ||
              item.id == 'btn_rb' ||
              item.id == 'btn_rt';
          final base = switch (item.type) {
            LayoutElementType.leftJoystick ||
            LayoutElementType.rightJoystick =>
              shortest * 0.29,
            LayoutElementType.dpad => shortest * 0.26,
            LayoutElementType.comboButton => shortest * 0.13,
            LayoutElementType.singleButton => shortest * 0.13,
          };
          final scaled =
              (base * 1.0 * item.scale).clamp(28.0, shortest * 0.58).toDouble();
          final ew = isBumper
              ? scaled * 1.48
              : (item.isCombo ? scaled * 1.35 : scaled);
          final eh = isBumper ? scaled * 0.78 : scaled;
          final left = ((item.x * w) - (ew / 2))
              .clamp(4.0, math.max(4.0, w - ew - 4.0))
              .toDouble();
          final top = ((item.y * h) - (eh / 2))
              .clamp(4.0, math.max(4.0, h - eh - 4.0))
              .toDouble();
          rects.add((id: item.id, l: left, t: top, r: left + ew, b: top + eh));
        }

        for (var i = 0; i < rects.length; i++) {
          for (var j = i + 1; j < rects.length; j++) {
            final a = rects[i];
            final b = rects[j];
            final overlaps = a.l < b.r - 1.0 &&
                a.r > b.l + 1.0 &&
                a.t < b.b - 1.0 &&
                a.b > b.t + 1.0;
            expect(
              overlaps,
              isFalse,
              reason:
                  'Overlap detected on ${w.toInt()}x${h.toInt()} between ${a.id} ($a) and ${b.id} ($b)',
            );
          }
        }
      }
    });
  });
}
