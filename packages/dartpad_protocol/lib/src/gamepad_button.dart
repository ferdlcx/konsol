/// Unified internal gamepad button representation used across both
/// Xbox and PlayStation layouts and protocols.
enum GamepadButton {
  south(0),
  east(1),
  west(2),
  north(3),
  leftShoulder(4),
  rightShoulder(5),
  leftTrigger(6),
  rightTrigger(7),
  dpadUp(8),
  dpadDown(9),
  dpadLeft(10),
  dpadRight(11),
  start(12),
  select(13),
  guide(14),
  leftStick(15),
  rightStick(16);

  /// Bit position (0..31) used in the 32-bit button bitmask in binary packets.
  final int bitIndex;

  const GamepadButton(this.bitIndex);

  /// Bitmask value (`1 << bitIndex`) for this button.
  int get bitMask => 1 << bitIndex;

  /// Encodes a set of pressed [GamepadButton]s into a 32-bit unsigned integer bitmask.
  static int encodeBitmask(Iterable<GamepadButton> pressedButtons) {
    var mask = 0;
    for (final button in pressedButtons) {
      mask |= button.bitMask;
    }
    return mask & 0xFFFFFFFF;
  }

  /// Decodes a 32-bit unsigned integer bitmask back into a [Set] of pressed [GamepadButton]s.
  static Set<GamepadButton> decodeBitmask(int mask) {
    final result = <GamepadButton>{};
    for (final button in GamepadButton.values) {
      if ((mask & button.bitMask) != 0) {
        result.add(button);
      }
    }
    return result;
  }
}

/// Controller layout / output style preset.
enum ControllerType {
  xbox,
  playstation;

  /// Returns the display label for a [GamepadButton] according to this preset.
  String labelFor(GamepadButton button) {
    switch (this) {
      case ControllerType.xbox:
        return switch (button) {
          GamepadButton.south => 'A',
          GamepadButton.east => 'B',
          GamepadButton.west => 'X',
          GamepadButton.north => 'Y',
          GamepadButton.leftShoulder => 'LB',
          GamepadButton.rightShoulder => 'RB',
          GamepadButton.leftTrigger => 'LT',
          GamepadButton.rightTrigger => 'RT',
          GamepadButton.dpadUp => 'Up',
          GamepadButton.dpadDown => 'Down',
          GamepadButton.dpadLeft => 'Left',
          GamepadButton.dpadRight => 'Right',
          GamepadButton.start => 'Menu',
          GamepadButton.select => 'View',
          GamepadButton.guide => 'Xbox',
          GamepadButton.leftStick => 'LS',
          GamepadButton.rightStick => 'RS',
        };
      case ControllerType.playstation:
        return switch (button) {
          GamepadButton.south => 'Cross',
          GamepadButton.east => 'Circle',
          GamepadButton.west => 'Square',
          GamepadButton.north => 'Triangle',
          GamepadButton.leftShoulder => 'L1',
          GamepadButton.rightShoulder => 'R1',
          GamepadButton.leftTrigger => 'L2',
          GamepadButton.rightTrigger => 'R2',
          GamepadButton.dpadUp => 'Up',
          GamepadButton.dpadDown => 'Down',
          GamepadButton.dpadLeft => 'Left',
          GamepadButton.dpadRight => 'Right',
          GamepadButton.start => 'Options',
          GamepadButton.select => 'Create',
          GamepadButton.guide => 'PS',
          GamepadButton.leftStick => 'L3',
          GamepadButton.rightStick => 'R3',
        };
    }
  }
}
