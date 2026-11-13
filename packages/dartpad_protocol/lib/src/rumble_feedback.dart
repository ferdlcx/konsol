import 'packet_codec.dart';

/// Represents a Force Feedback / Rumble event sent from the Windows PC Game
/// (via the Virtual Gamepad Driver notification callback) back to the Android
/// phone (`PacketType.rumble`), or triggered locally on button/combo press.
class RumbleEvent {
  /// Low-frequency (heavy) motor intensity (`0.0` .. `1.0`).
  final double largeMotor;

  /// High-frequency (sharp) motor intensity (`0.0` .. `1.0`).
  final double smallMotor;

  /// Suggested vibration duration in milliseconds.
  final int durationMs;

  const RumbleEvent({
    required this.largeMotor,
    required this.smallMotor,
    this.durationMs = 60,
  });

  /// Creates a [RumbleEvent] from raw 8-bit motor values (`0..255`) reported by
  /// XInput / ViGEm (`XUSB` or `DS4` force feedback callbacks).
  factory RumbleEvent.fromRawMotors({
    required int largeMotorByte,
    required int smallMotorByte,
    int durationMs = 60,
  }) {
    return RumbleEvent(
      largeMotor: (largeMotorByte.clamp(0, 255)) / 255.0,
      smallMotor: (smallMotorByte.clamp(0, 255)) / 255.0,
      durationMs: durationMs,
    );
  }

  /// Peak combined intensity (`0.0` .. `1.0`).
  double get peakIntensity =>
      largeMotor > smallMotor ? largeMotor : smallMotor;

  /// Whether both motors are silent (`0`).
  bool get isSilent => largeMotor <= 0.01 && smallMotor <= 0.01;

  /// Converts this rumble event into a [ControlPacket] (`PacketType.rumble`)
  /// to be sent over UDP from the Windows Receiver to the Android phone.
  ControlPacket toControlPacket({required int sequence, required int timestampMs}) {
    return ControlPacket(
      type: PacketType.rumble,
      sequence: sequence,
      timestampMs: timestampMs,
      payload: {
        'largeMotor': (largeMotor.clamp(0.0, 1.0) * 255).round(),
        'smallMotor': (smallMotor.clamp(0.0, 1.0) * 255).round(),
        'durationMs': durationMs,
      },
    );
  }

  /// Extracts a [RumbleEvent] from a decoded `PacketType.rumble` [ControlPacket].
  factory RumbleEvent.fromControlPacket(ControlPacket packet) {
    final lByte = (packet.payload['largeMotor'] as num?)?.toInt() ?? 0;
    final sByte = (packet.payload['smallMotor'] as num?)?.toInt() ?? 0;
    final dur = (packet.payload['durationMs'] as num?)?.toInt() ?? 60;
    return RumbleEvent.fromRawMotors(
      largeMotorByte: lByte,
      smallMotorByte: sByte,
      durationMs: dur,
    );
  }

  @override
  String toString() =>
      'RumbleEvent(large: ${(largeMotor * 100).round()}%, small: ${(smallMotor * 100).round()}%, ${durationMs}ms)';
}
