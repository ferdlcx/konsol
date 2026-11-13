import 'controller_state.dart';
import 'gamepad_button.dart';

/// Type of interactive widget placed on the customizable controller canvas.
enum LayoutElementType {
  singleButton,
  comboButton,
  dpad,
  leftJoystick,
  rightJoystick;
}

/// Customizable placement, size, appearance, and action binding for a single
/// element on the controller layout canvas.
///
/// Coordinates ([x], [y]) are stored as normalized screen percentages (`0.0 .. 1.0`)
/// so the layout adapts cleanly across different phone screen resolutions.
class ButtonLayoutItem {
  final String id;
  final String label;
  final LayoutElementType type;

  /// Normalized horizontal position (`0.0` = left edge, `1.0` = right edge).
  final double x;

  /// Normalized vertical position (`0.0` = top edge, `1.0` = bottom edge).
  final double y;

  /// Scale multiplier (`0.5` = 50% size, `1.0` = 100% default, `2.5` = 250% size).
  final double scale;

  /// Opacity (`0.1` .. `1.0`, default `0.85`).
  final double opacity;

  /// Whether this button/element is visible and active on the controller screen.
  final bool visible;

  /// Optional ARGB hex color override (e.g., `0xFF00E5FF`).
  final int? colorHex;

  /// One or more [GamepadButton]s triggered simultaneously when this element is pressed.
  /// - For `singleButton`: contains 1 button (e.g. `[GamepadButton.south]`).
  /// - For `comboButton`: contains 2+ buttons pressed together (e.g. `[GamepadButton.leftShoulder, GamepadButton.rightShoulder]` or `[GamepadButton.south, GamepadButton.east]`).
  final List<GamepadButton> actions;

  const ButtonLayoutItem({
    required this.id,
    required this.label,
    required this.type,
    required this.x,
    required this.y,
    this.scale = 1.0,
    this.opacity = 0.85,
    this.visible = true,
    this.colorHex,
    this.actions = const [],
  });

  bool get isCombo => type == LayoutElementType.comboButton || actions.length > 1;

  /// Returns a new [ButtonLayoutItem] with updated position/size/combo properties.
  ButtonLayoutItem copyWith({
    String? id,
    String? label,
    LayoutElementType? type,
    double? x,
    double? y,
    double? scale,
    double? opacity,
    bool? visible,
    int? colorHex,
    List<GamepadButton>? actions,
  }) {
    return ButtonLayoutItem(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      x: (x ?? this.x).clamp(0.0, 1.0),
      y: (y ?? this.y).clamp(0.0, 1.0),
      scale: (scale ?? this.scale).clamp(0.4, 3.0),
      opacity: (opacity ?? this.opacity).clamp(0.1, 1.0),
      visible: visible ?? this.visible,
      colorHex: colorHex ?? this.colorHex,
      actions: actions ?? this.actions,
    );
  }

  /// Applies this element's [actions] (single or multi-button combo) onto [current] state.
  /// Also updates analog `leftTrigger` / `rightTrigger` values if `LT` / `RT` are part of the combo.
  ControllerState applyToState({
    required ControllerState current,
    required bool isPressed,
  }) {
    if (!visible || actions.isEmpty) return current;

    final updatedButtons = Set<GamepadButton>.from(current.buttons);
    var lt = current.leftTrigger;
    var rt = current.rightTrigger;

    for (final btn in actions) {
      if (isPressed) {
        updatedButtons.add(btn);
      } else {
        updatedButtons.remove(btn);
      }
      if (btn == GamepadButton.leftTrigger) {
        lt = isPressed ? 1.0 : 0.0;
      } else if (btn == GamepadButton.rightTrigger) {
        rt = isPressed ? 1.0 : 0.0;
      }
    }

    return current.copyWith(
      buttons: updatedButtons,
      leftTrigger: lt,
      rightTrigger: rt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'type': type.name,
        'x': x,
        'y': y,
        'scale': scale,
        'opacity': opacity,
        'visible': visible,
        if (colorHex != null) 'colorHex': colorHex,
        'actions': actions.map((a) => a.name).toList(),
      };

  factory ButtonLayoutItem.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'singleButton';
    final type = LayoutElementType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => LayoutElementType.singleButton,
    );

    final rawActions = (json['actions'] as List<dynamic>?) ?? const [];
    final parsedActions = <GamepadButton>[];
    for (final item in rawActions) {
      for (final btn in GamepadButton.values) {
        if (btn.name == item) {
          parsedActions.add(btn);
          break;
        }
      }
    }

    return ButtonLayoutItem(
      id: json['id'] as String? ?? 'btn_custom',
      label: json['label'] as String? ?? 'BTN',
      type: type,
      x: ((json['x'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      y: ((json['y'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
      scale: ((json['scale'] as num?)?.toDouble() ?? 1.0).clamp(0.4, 3.0),
      opacity: ((json['opacity'] as num?)?.toDouble() ?? 0.85).clamp(0.1, 1.0),
      visible: json['visible'] as bool? ?? true,
      colorHex: json['colorHex'] as int?,
      actions: parsedActions,
    );
  }
}

/// Complete customizable controller layout containing standard controls and custom combo buttons.
class ControllerLayout {
  final String id;
  final String name;
  final List<ButtonLayoutItem> items;

  const ControllerLayout({
    required this.id,
    required this.name,
    required this.items,
  });

  /// Default landscape layout with standard controls + support for adding custom combo buttons.
  factory ControllerLayout.defaultLandscape({
    ControllerType preset = ControllerType.xbox,
  }) {
    String lbl(GamepadButton b) => preset.labelFor(b);

    return ControllerLayout(
      id: 'landscape_default',
      name: 'Default Landscape',
      items: [
        // Joysticks & D-Pad
        const ButtonLayoutItem(
          id: 'left_stick',
          label: 'LS',
          type: LayoutElementType.leftJoystick,
          x: 0.18,
          y: 0.68,
          scale: 1.0,
          actions: [GamepadButton.leftStick],
        ),
        const ButtonLayoutItem(
          id: 'right_stick',
          label: 'RS',
          type: LayoutElementType.rightJoystick,
          x: 0.68,
          y: 0.68,
          scale: 1.0,
          actions: [GamepadButton.rightStick],
        ),
        const ButtonLayoutItem(
          id: 'dpad',
          label: 'D-Pad',
          type: LayoutElementType.dpad,
          x: 0.28,
          y: 0.42,
          scale: 1.0,
          actions: [
            GamepadButton.dpadUp,
            GamepadButton.dpadDown,
            GamepadButton.dpadLeft,
            GamepadButton.dpadRight,
          ],
        ),
        // Shoulders & Triggers
        ButtonLayoutItem(
          id: 'btn_lt',
          label: lbl(GamepadButton.leftTrigger),
          type: LayoutElementType.singleButton,
          x: 0.10,
          y: 0.14,
          scale: 1.0,
          actions: const [GamepadButton.leftTrigger],
        ),
        ButtonLayoutItem(
          id: 'btn_lb',
          label: lbl(GamepadButton.leftShoulder),
          type: LayoutElementType.singleButton,
          x: 0.22,
          y: 0.14,
          scale: 1.0,
          actions: const [GamepadButton.leftShoulder],
        ),
        ButtonLayoutItem(
          id: 'btn_rb',
          label: lbl(GamepadButton.rightShoulder),
          type: LayoutElementType.singleButton,
          x: 0.78,
          y: 0.14,
          scale: 1.0,
          actions: const [GamepadButton.rightShoulder],
        ),
        ButtonLayoutItem(
          id: 'btn_rt',
          label: lbl(GamepadButton.rightTrigger),
          type: LayoutElementType.singleButton,
          x: 0.90,
          y: 0.14,
          scale: 1.0,
          actions: const [GamepadButton.rightTrigger],
        ),
        // Face Buttons (South, East, West, North)
        ButtonLayoutItem(
          id: 'btn_south',
          label: lbl(GamepadButton.south),
          type: LayoutElementType.singleButton,
          x: 0.82,
          y: 0.56,
          scale: 1.0,
          actions: const [GamepadButton.south],
        ),
        ButtonLayoutItem(
          id: 'btn_east',
          label: lbl(GamepadButton.east),
          type: LayoutElementType.singleButton,
          x: 0.90,
          y: 0.44,
          scale: 1.0,
          actions: const [GamepadButton.east],
        ),
        ButtonLayoutItem(
          id: 'btn_west',
          label: lbl(GamepadButton.west),
          type: LayoutElementType.singleButton,
          x: 0.74,
          y: 0.44,
          scale: 1.0,
          actions: const [GamepadButton.west],
        ),
        ButtonLayoutItem(
          id: 'btn_north',
          label: lbl(GamepadButton.north),
          type: LayoutElementType.singleButton,
          x: 0.82,
          y: 0.32,
          scale: 1.0,
          actions: const [GamepadButton.north],
        ),
        // Center System Buttons
        ButtonLayoutItem(
          id: 'btn_select',
          label: lbl(GamepadButton.select),
          type: LayoutElementType.singleButton,
          x: 0.42,
          y: 0.22,
          scale: 0.85,
          actions: const [GamepadButton.select],
        ),
        ButtonLayoutItem(
          id: 'btn_guide',
          label: lbl(GamepadButton.guide),
          type: LayoutElementType.singleButton,
          x: 0.50,
          y: 0.22,
          scale: 0.95,
          actions: const [GamepadButton.guide],
        ),
        ButtonLayoutItem(
          id: 'btn_start',
          label: lbl(GamepadButton.start),
          type: LayoutElementType.singleButton,
          x: 0.58,
          y: 0.22,
          scale: 0.85,
          actions: const [GamepadButton.start],
        ),
      ],
    );
  }

  /// Moves and/or resizes an item by [itemId] in the layout editor.
  ControllerLayout updateItem(
    String itemId,
    ButtonLayoutItem Function(ButtonLayoutItem current) updater,
  ) {
    return ControllerLayout(
      id: id,
      name: name,
      items: [
        for (final item in items)
          if (item.id == itemId) updater(item) else item,
      ],
    );
  }

  /// Adds a new custom Combo / Macro button (e.g., `LB + RB` or `Y + B`) at the specified coordinates and size.
  ControllerLayout addComboButton({
    required String id,
    required String label,
    required List<GamepadButton> comboActions,
    double x = 0.50,
    double y = 0.50,
    double scale = 1.0,
    double opacity = 0.85,
    int? colorHex,
  }) {
    if (comboActions.isEmpty) {
      throw ArgumentError('comboActions must contain at least one GamepadButton');
    }
    final newItem = ButtonLayoutItem(
      id: id,
      label: label,
      type: LayoutElementType.comboButton,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
      scale: scale.clamp(0.4, 3.0),
      opacity: opacity.clamp(0.1, 1.0),
      colorHex: colorHex,
      actions: List.unmodifiable(comboActions),
    );
    return ControllerLayout(
      id: id,
      name: name,
      items: [...items.where((e) => e.id != id), newItem],
    );
  }

  /// Removes a custom button by [itemId].
  ControllerLayout removeItem(String itemId) {
    return ControllerLayout(
      id: id,
      name: name,
      items: items.where((item) => item.id != itemId).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory ControllerLayout.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>?) ?? const [];
    return ControllerLayout(
      id: json['id'] as String? ?? 'custom_layout',
      name: json['name'] as String? ?? 'Custom Layout',
      items: [
        for (final item in rawItems)
          if (item is Map<String, dynamic>) ButtonLayoutItem.fromJson(item),
      ],
    );
  }
}
