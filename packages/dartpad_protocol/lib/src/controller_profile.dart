import 'controller_state.dart';
import 'gamepad_button.dart';

/// Physical hardware keys on the Android device that can be mapped to gamepad buttons/triggers.
enum HardwareKey {
  volumeUp,
  volumeDown;
}

/// Represents a customizable controller profile (Xbox, PlayStation, or user-defined).
class ControllerProfile {
  final String id;
  final String name;
  final ControllerType type;
  final double deadzone;
  final double sensitivity;
  final Map<GamepadButton, String> buttonLabels;

  /// Maps physical phone keys (e.g., Volume Up / Volume Down) to virtual [GamepadButton]s
  /// (defaults to `LT` / `RT` or `L1` / `R1`).
  final bool enableVolumeKeysAsTriggers;
  final Map<HardwareKey, GamepadButton> hardwareKeyBindings;

  const ControllerProfile({
    required this.id,
    required this.name,
    required this.type,
    this.deadzone = 0.08,
    this.sensitivity = 1.0,
    required this.buttonLabels,
    this.enableVolumeKeysAsTriggers = true,
    this.hardwareKeyBindings = const {
      HardwareKey.volumeUp: GamepadButton.leftTrigger,
      HardwareKey.volumeDown: GamepadButton.rightTrigger,
    },
  });

  /// Preset 01: Xbox Default Profile
  factory ControllerProfile.xboxDefault() {
    return ControllerProfile(
      id: 'xbox_default',
      name: 'Xbox Default',
      type: ControllerType.xbox,
      deadzone: 0.08,
      sensitivity: 1.0,
      buttonLabels: {
        for (final button in GamepadButton.values)
          button: ControllerType.xbox.labelFor(button),
      },
    );
  }

  /// Preset 02: PlayStation Default Profile
  factory ControllerProfile.playstationDefault() {
    return ControllerProfile(
      id: 'ps_default',
      name: 'PlayStation Default',
      type: ControllerType.playstation,
      deadzone: 0.08,
      sensitivity: 1.0,
      buttonLabels: {
        for (final button in GamepadButton.values)
          button: ControllerType.playstation.labelFor(button),
      },
    );
  }

  String labelFor(GamepadButton button) =>
      buttonLabels[button] ?? type.labelFor(button);

  /// Translates a physical [HardwareKey] press/release into an updated [ControllerState].
  /// If mapped to `leftTrigger` or `rightTrigger`, it also sets the analog trigger axis to `1.0` / `0.0`.
  ControllerState applyHardwareKey({
    required ControllerState current,
    required HardwareKey key,
    required bool isPressed,
  }) {
    if (!enableVolumeKeysAsTriggers) return current;
    final targetButton = hardwareKeyBindings[key];
    if (targetButton == null) return current;

    final updatedButtons = Set<GamepadButton>.from(current.buttons);
    if (isPressed) {
      updatedButtons.add(targetButton);
    } else {
      updatedButtons.remove(targetButton);
    }

    var lt = current.leftTrigger;
    var rt = current.rightTrigger;
    if (targetButton == GamepadButton.leftTrigger) {
      lt = isPressed ? 1.0 : 0.0;
    } else if (targetButton == GamepadButton.rightTrigger) {
      rt = isPressed ? 1.0 : 0.0;
    }

    return current.copyWith(
      buttons: updatedButtons,
      leftTrigger: lt,
      rightTrigger: rt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'deadzone': deadzone,
        'sensitivity': sensitivity,
        'enableVolumeKeysAsTriggers': enableVolumeKeysAsTriggers,
        'hardwareKeyBindings': {
          for (final entry in hardwareKeyBindings.entries)
            entry.key.name: entry.value.name,
        },
        'buttons': {
          for (final entry in buttonLabels.entries) entry.key.name: entry.value,
        },
      };

  factory ControllerProfile.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'xbox';
    final type = ControllerType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => ControllerType.xbox,
    );

    final rawButtons = json['buttons'] as Map<String, dynamic>? ?? const {};
    final labels = <GamepadButton, String>{
      for (final button in GamepadButton.values) button: type.labelFor(button),
    };
    for (final entry in rawButtons.entries) {
      for (final button in GamepadButton.values) {
        if (button.name == entry.key && entry.value is String) {
          labels[button] = entry.value as String;
          break;
        }
      }
    }

    final rawHwBindings =
        json['hardwareKeyBindings'] as Map<String, dynamic>? ?? const {};
    final hwBindings = <HardwareKey, GamepadButton>{
      HardwareKey.volumeUp: GamepadButton.leftTrigger,
      HardwareKey.volumeDown: GamepadButton.rightTrigger,
    };
    for (final entry in rawHwBindings.entries) {
      final hwKey = HardwareKey.values
          .where((k) => k.name == entry.key)
          .firstOrNull;
      final btn = GamepadButton.values
          .where((b) => b.name == entry.value)
          .firstOrNull;
      if (hwKey != null && btn != null) {
        hwBindings[hwKey] = btn;
      }
    }

    return ControllerProfile(
      id: json['id'] as String? ?? 'custom_profile',
      name: json['name'] as String? ?? 'Custom Profile',
      type: type,
      deadzone: ((json['deadzone'] as num?)?.toDouble() ?? 0.08).clamp(0.0, 0.5),
      sensitivity: ((json['sensitivity'] as num?)?.toDouble() ?? 1.0).clamp(0.1, 3.0),
      buttonLabels: labels,
      enableVolumeKeysAsTriggers:
          json['enableVolumeKeysAsTriggers'] as bool? ?? true,
      hardwareKeyBindings: hwBindings,
    );
  }
}
