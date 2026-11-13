import 'dart:math' as math;
import 'gamepad_button.dart';

/// Represents the normalized state of a 2D analog stick.
///
/// Range:
/// - [x]: -1.0 (left) to 1.0 (right), 0.0 is center.
/// - [y]: -1.0 (down/up depending on convention; normalized -1.0..1.0), 0.0 is center.
class StickState {
  final double x;
  final double y;

  const StickState({
    this.x = 0.0,
    this.y = 0.0,
  });

  static const StickState zero = StickState(x: 0.0, y: 0.0);

  /// Magnitude (distance from center), clamped to [0.0, 1.0] when circular boundary is enforced.
  double get magnitude => math.sqrt(x * x + y * y);

  /// Angle in radians (`-pi` to `pi`).
  double get angle => math.atan2(y, x);

  /// Applies radial deadzone, sensitivity scaling, and circular boundary clamping.
  StickState normalize({
    double deadzone = 0.08,
    double sensitivity = 1.0,
    bool clampCircular = true,
  }) {
    final mag = magnitude;
    if (mag <= deadzone || mag == 0.0) {
      return StickState.zero;
    }

    // Rescale magnitude smoothly from [deadzone..1.0] to [0.0..1.0]
    final rescaledMag = ((mag - deadzone) / (1.0 - deadzone)) * sensitivity;
    final finalMag = clampCircular ? rescaledMag.clamp(0.0, 1.0) : rescaledMag;

    final unitX = x / mag;
    final unitY = y / mag;

    return StickState(
      x: (unitX * finalMag).clamp(-1.0, 1.0),
      y: (unitY * finalMag).clamp(-1.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
      };

  factory StickState.fromJson(Map<String, dynamic> json) {
    return StickState(
      x: (json['x'] as num?)?.toDouble() ?? 0.0,
      y: (json['y'] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StickState &&
          (x - other.x).abs() < 1e-4 &&
          (y - other.y).abs() < 1e-4;

  @override
  int get hashCode => Object.hash((x * 10000).round(), (y * 10000).round());

  @override
  String toString() =>
      'StickState(x: ${x.toStringAsFixed(3)}, y: ${y.toStringAsFixed(3)})';
}

/// Complete snapshot of the virtual controller state at a point in time.
class ControllerState {
  final Set<GamepadButton> buttons;
  final StickState leftStick;
  final StickState rightStick;
  final double leftTrigger;
  final double rightTrigger;

  const ControllerState({
    this.buttons = const {},
    this.leftStick = StickState.zero,
    this.rightStick = StickState.zero,
    this.leftTrigger = 0.0,
    this.rightTrigger = 0.0,
  });

  /// Neutral state with all buttons released and sticks/triggers at 0.0 (used by auto-release / watchdog).
  static const ControllerState neutral = ControllerState();

  /// Integer bitmask representing all currently pressed [buttons].
  int get buttonBitmask => GamepadButton.encodeBitmask(buttons);

  bool isPressed(GamepadButton button) => buttons.contains(button);

  ControllerState copyWith({
    Set<GamepadButton>? buttons,
    StickState? leftStick,
    StickState? rightStick,
    double? leftTrigger,
    double? rightTrigger,
  }) {
    return ControllerState(
      buttons: buttons ?? this.buttons,
      leftStick: leftStick ?? this.leftStick,
      rightStick: rightStick ?? this.rightStick,
      leftTrigger: leftTrigger ?? this.leftTrigger,
      rightTrigger: rightTrigger ?? this.rightTrigger,
    );
  }

  Map<String, dynamic> toJson() => {
        'buttons': buttons.map((b) => b.name).toList(),
        'leftStick': leftStick.toJson(),
        'rightStick': rightStick.toJson(),
        'leftTrigger': leftTrigger,
        'rightTrigger': rightTrigger,
      };

  factory ControllerState.fromJson(Map<String, dynamic> json) {
    final rawButtons = (json['buttons'] as List<dynamic>?) ?? const [];
    final parsedButtons = <GamepadButton>{};
    for (final item in rawButtons) {
      for (final candidate in GamepadButton.values) {
        if (candidate.name == item) {
          parsedButtons.add(candidate);
          break;
        }
      }
    }

    return ControllerState(
      buttons: parsedButtons,
      leftStick: json['leftStick'] is Map<String, dynamic>
          ? StickState.fromJson(json['leftStick'] as Map<String, dynamic>)
          : StickState.zero,
      rightStick: json['rightStick'] is Map<String, dynamic>
          ? StickState.fromJson(json['rightStick'] as Map<String, dynamic>)
          : StickState.zero,
      leftTrigger: ((json['leftTrigger'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      rightTrigger: ((json['rightTrigger'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
    );
  }

  @override
  String toString() =>
      'ControllerState(buttons: ${buttons.map((b) => b.name).join(",")}, '
      'L: $leftStick, R: $rightStick, LT: ${leftTrigger.toStringAsFixed(2)}, RT: ${rightTrigger.toStringAsFixed(2)})';
}
