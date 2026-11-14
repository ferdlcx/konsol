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

/// Execution mode for a Combo / Macro button:
/// - [simultaneous]: Presses all buttons in `actions` at the exact same instant.
/// - [sequence]: Presses each button in `actions` one after another (e.g. `X -> Y -> A -> A`)
///   with a configurable millisecond interval ([stepDelayMs]).
enum ComboExecutionMode {
  simultaneous,
  sequence;
}

/// Customizable placement, size, appearance, and action binding for a single
/// element on the controller layout canvas.
///
/// Coordinates ([x], [y]) are stored as normalized screen percentages (`0.0 .. 1.0`)
/// so the layout adapts cleanly across different phone screen resolutions without overlapping.
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

  /// Opacity (`0.1` .. `1.0`, default `0.90`).
  final double opacity;

  /// Whether this button/element is visible and active on the controller screen.
  final bool visible;

  /// Optional ARGB hex color override (e.g., `0xFF107C10`).
  final int? colorHex;

  /// Ordered list of [GamepadButton]s triggered by this element.
  /// Can contain duplicate buttons in order for sequence macros, e.g.:
  /// `[GamepadButton.west, GamepadButton.north, GamepadButton.south, GamepadButton.south]` (`X, Y, A, A`).
  final List<GamepadButton> actions;

  /// Whether this combo executes all buttons simultaneously or sequentially in milliseconds.
  final ComboExecutionMode comboMode;

  /// Delay in milliseconds between each step when [comboMode] is [ComboExecutionMode.sequence].
  /// Default is `75` ms per button step.
  final int stepDelayMs;

  const ButtonLayoutItem({
    required this.id,
    required this.label,
    required this.type,
    required this.x,
    required this.y,
    this.scale = 1.0,
    this.opacity = 0.90,
    this.visible = true,
    this.colorHex,
    this.actions = const [],
    this.comboMode = ComboExecutionMode.simultaneous,
    this.stepDelayMs = 75,
  });

  bool get isCombo =>
      type == LayoutElementType.comboButton || actions.length > 1;

  /// Returns a human-readable summary of the combo sequence (e.g. `X → Y → A → A (75ms)` or `LB + RB`).
  String describeCombo(ControllerType preset) {
    if (actions.isEmpty) return label;
    final names = actions.map((b) => preset.labelFor(b)).toList();
    if (comboMode == ComboExecutionMode.sequence) {
      return '${names.join("→")} (${stepDelayMs}ms)';
    }
    return names.join('+');
  }

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
    ComboExecutionMode? comboMode,
    int? stepDelayMs,
  }) {
    return ButtonLayoutItem(
      id: id ?? this.id,
      label: label ?? this.label,
      type: type ?? this.type,
      x: (x ?? this.x).clamp(0.04, 0.96),
      y: (y ?? this.y).clamp(0.06, 0.94),
      scale: (scale ?? this.scale).clamp(0.4, 2.5),
      opacity: (opacity ?? this.opacity).clamp(0.15, 1.0),
      visible: visible ?? this.visible,
      colorHex: colorHex ?? this.colorHex,
      actions: actions ?? this.actions,
      comboMode: comboMode ?? this.comboMode,
      stepDelayMs: (stepDelayMs ?? this.stepDelayMs).clamp(0, 2000),
    );
  }

  /// Applies this element's [actions] onto [current] state when in simultaneous mode.
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
        'comboMode': comboMode.name,
        'stepDelayMs': stepDelayMs,
      };

  factory ButtonLayoutItem.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'singleButton';
    final type = LayoutElementType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => LayoutElementType.singleButton,
    );

    final modeName = json['comboMode'] as String? ?? 'simultaneous';
    final comboMode = ComboExecutionMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => ComboExecutionMode.simultaneous,
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
      x: ((json['x'] as num?)?.toDouble() ?? 0.5).clamp(0.04, 0.96),
      y: ((json['y'] as num?)?.toDouble() ?? 0.5).clamp(0.06, 0.94),
      scale: ((json['scale'] as num?)?.toDouble() ?? 1.0).clamp(0.4, 2.5),
      opacity: ((json['opacity'] as num?)?.toDouble() ?? 0.90).clamp(0.15, 1.0),
      visible: json['visible'] as bool? ?? true,
      colorHex: json['colorHex'] as int?,
      actions: parsedActions,
      comboMode: comboMode,
      stepDelayMs: ((json['stepDelayMs'] as num?)?.toInt() ?? 75).clamp(0, 2000),
    );
  }
}

/// Complete customizable controller layout modelled after an authentic Xbox Series
/// Controller layout with zero overlapping elements and built-in `(1)` / `(2)` Combo buttons.
class ControllerLayout {
  final String id;
  final String name;
  final List<ButtonLayoutItem> items;

  const ControllerLayout({
    required this.id,
    required this.name,
    required this.items,
  });

  /// Authentic Xbox Asymmetric Landscape Layout (Anti-Overlap):
  /// - Upper-Left: Left Stick (`LS`)
  /// - Lower-Left Inner: 4-Way Cross `D-Pad`
  /// - Upper-Right: Diamond `Y / X / B / A` with authentic Xbox color accents
  /// - Lower-Right Inner: Right Stick (`RS`)
  /// - Top Bumpers: `LT` & `LB` (Left), `RB` & `RT` (Right)
  /// - Center System Row: `View`, `Xbox`, `Menu`
  /// - Center-Bottom Macro Row: Pre-configured Combo `(1)` (`X → Y → A → A`, 75ms sequence)
  ///   and Combo `(2)` (`LB + RB` instant).
  factory ControllerLayout.defaultLandscape({
    ControllerType preset = ControllerType.xbox,
  }) {
    String lbl(GamepadButton b) => preset.labelFor(b);

    return ControllerLayout(
      id: 'xbox_authentic_v2',
      name: 'Xbox Authentic Layout (Big Controls)',
      items: [
        // 1. Left Analog Stick (~1.5x diameter / ~2.25x touch area, Upper-Left)
        const ButtonLayoutItem(
          id: 'left_stick',
          label: 'LS',
          type: LayoutElementType.leftJoystick,
          x: 0.125,
          y: 0.48,
          scale: 1.50,
          actions: [GamepadButton.leftStick],
        ),

        // 2. D-Pad Cross (Lower-Left Inner, well separated from LS)
        const ButtonLayoutItem(
          id: 'dpad',
          label: 'D-Pad',
          type: LayoutElementType.dpad,
          x: 0.335,
          y: 0.79,
          scale: 1.0,
          actions: [
            GamepadButton.dpadUp,
            GamepadButton.dpadDown,
            GamepadButton.dpadLeft,
            GamepadButton.dpadRight,
          ],
        ),

        // 3. Right Analog Stick (Lower-Right Inner, well separated from ABXY)
        const ButtonLayoutItem(
          id: 'right_stick',
          label: 'RS',
          type: LayoutElementType.rightJoystick,
          x: 0.605,
          y: 0.78,
          scale: 1.0,
          actions: [GamepadButton.rightStick],
        ),

        // 4. Top Left Triggers & Shoulders (LT, LB — ~2x larger ergonomic pads)
        ButtonLayoutItem(
          id: 'btn_lt',
          label: lbl(GamepadButton.leftTrigger),
          type: LayoutElementType.singleButton,
          x: 0.08,
          y: 0.10,
          scale: 1.55,
          colorHex: 0xFF222B3A,
          actions: const [GamepadButton.leftTrigger],
        ),
        ButtonLayoutItem(
          id: 'btn_lb',
          label: lbl(GamepadButton.leftShoulder),
          type: LayoutElementType.singleButton,
          x: 0.255,
          y: 0.10,
          scale: 1.55,
          colorHex: 0xFF222B3A,
          actions: const [GamepadButton.leftShoulder],
        ),

        // 5. Top Right Shoulders & Triggers (RB, RT — ~2x larger ergonomic pads)
        ButtonLayoutItem(
          id: 'btn_rb',
          label: lbl(GamepadButton.rightShoulder),
          type: LayoutElementType.singleButton,
          x: 0.745,
          y: 0.10,
          scale: 1.55,
          colorHex: 0xFF222B3A,
          actions: const [GamepadButton.rightShoulder],
        ),
        ButtonLayoutItem(
          id: 'btn_rt',
          label: lbl(GamepadButton.rightTrigger),
          type: LayoutElementType.singleButton,
          x: 0.92,
          y: 0.10,
          scale: 1.55,
          colorHex: 0xFF222B3A,
          actions: const [GamepadButton.rightTrigger],
        ),

        // 6. Upper-Right Diamond Face Buttons (Y, X, B, A — ~2x larger thumbs)
        ButtonLayoutItem(
          id: 'btn_north',
          label: lbl(GamepadButton.north), // Y (Yellow)
          type: LayoutElementType.singleButton,
          x: 0.855,
          y: 0.34,
          scale: 1.72,
          colorHex: 0xFFF5B000,
          actions: const [GamepadButton.north],
        ),
        ButtonLayoutItem(
          id: 'btn_west',
          label: lbl(GamepadButton.west), // X (Blue)
          type: LayoutElementType.singleButton,
          x: 0.755,
          y: 0.57,
          scale: 1.72,
          colorHex: 0xFF0078D7,
          actions: const [GamepadButton.west],
        ),
        ButtonLayoutItem(
          id: 'btn_east',
          label: lbl(GamepadButton.east), // B (Red)
          type: LayoutElementType.singleButton,
          x: 0.945,
          y: 0.57,
          scale: 1.72,
          colorHex: 0xFFE81123,
          actions: const [GamepadButton.east],
        ),
        ButtonLayoutItem(
          id: 'btn_south',
          label: lbl(GamepadButton.south), // A (Green)
          type: LayoutElementType.singleButton,
          x: 0.855,
          y: 0.81,
          scale: 1.72,
          colorHex: 0xFF107C10,
          actions: const [GamepadButton.south],
        ),

        // 7. Center System Buttons (View, Xbox Guide, Menu — below top bar)
        ButtonLayoutItem(
          id: 'btn_select',
          label: lbl(GamepadButton.select),
          type: LayoutElementType.singleButton,
          x: 0.415,
          y: 0.25,
          scale: 0.78,
          colorHex: 0xFF232D3F,
          actions: const [GamepadButton.select],
        ),
        ButtonLayoutItem(
          id: 'btn_guide',
          label: lbl(GamepadButton.guide),
          type: LayoutElementType.singleButton,
          x: 0.495,
          y: 0.24,
          scale: 0.90,
          colorHex: 0xFF107C10,
          actions: const [GamepadButton.guide],
        ),
        ButtonLayoutItem(
          id: 'btn_start',
          label: lbl(GamepadButton.start),
          type: LayoutElementType.singleButton,
          x: 0.575,
          y: 0.25,
          scale: 0.78,
          colorHex: 0xFF232D3F,
          actions: const [GamepadButton.start],
        ),

        // 8. Built-in Default Combo Buttons:
        // (1) Sequential Macro: X -> Y -> A -> A (75ms per step)
        const ButtonLayoutItem(
          id: 'combo_1',
          label: '(1)',
          type: LayoutElementType.comboButton,
          x: 0.475,
          y: 0.41,
          scale: 1.0,
          colorHex: 0xFFFF4081,
          comboMode: ComboExecutionMode.sequence,
          stepDelayMs: 75,
          actions: [
            GamepadButton.west, // X
            GamepadButton.north, // Y
            GamepadButton.south, // A
            GamepadButton.south, // A
          ],
        ),
        // (2) Instant Combo: LB + RB (Simultaneous)
        const ButtonLayoutItem(
          id: 'combo_2',
          label: '(2)',
          type: LayoutElementType.comboButton,
          x: 0.475,
          y: 0.58,
          scale: 1.0,
          colorHex: 0xFF7C4DFF,
          comboMode: ComboExecutionMode.simultaneous,
          stepDelayMs: 0,
          actions: [
            GamepadButton.leftShoulder,
            GamepadButton.rightShoulder,
          ],
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

  /// Adds or updates a custom Combo / Macro button (supports both simultaneous
  /// combos like `LB + RB` and sequential millisecond macros like `X -> Y -> A -> A`).
  ControllerLayout addComboButton({
    required String id,
    required String label,
    required List<GamepadButton> comboActions,
    ComboExecutionMode comboMode = ComboExecutionMode.simultaneous,
    int stepDelayMs = 75,
    double x = 0.50,
    double y = 0.52,
    double scale = 1.0,
    double opacity = 0.90,
    int? colorHex,
  }) {
    if (comboActions.isEmpty) {
      throw ArgumentError(
          'comboActions must contain at least one GamepadButton');
    }
    final newItem = ButtonLayoutItem(
      id: id,
      label: label,
      type: LayoutElementType.comboButton,
      x: x.clamp(0.04, 0.96),
      y: y.clamp(0.06, 0.94),
      scale: scale.clamp(0.4, 2.5),
      opacity: opacity.clamp(0.15, 1.0),
      colorHex: colorHex ?? 0xFFFF4081,
      actions: List.unmodifiable(comboActions),
      comboMode: comboMode,
      stepDelayMs: stepDelayMs.clamp(0, 2000),
    );
    return ControllerLayout(
      id: this.id,
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
