import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/virtual_joystick.dart';

/// Main Controller & Interactive Layout Editor Screen for `dartpad_mobile`.
///
/// Features:
/// - **Zero-Delay Multi-Touch Controls**: Uses raw `Listener` pointer events
///   (`onPointerDown` / `onPointerUp`) instead of gesture recognizers to avoid
///   Flutter's ~100ms tap disambiguation delay.
/// - **Physical Volume Keys as Triggers (`LT` / `RT`)**: Intercepts Android
///   `LogicalKeyboardKey.audioVolumeUp` & `audioVolumeDown` so pressing volume
///   keys fires instant triggers without showing the system volume slider.
/// - **Interactive Layout Editor Mode**:
///   - Drag any button/joystick to reposition (`x`, `y`).
///   - Resize button size (`scale` slider `0.5x .. 2.5x`) and `opacity`.
///   - Create custom **Combo Buttons** (e.g., `LB + RB` or `Y + B` in 1 tap).
///   - Switch between **Xbox** and **PlayStation** presets seamlessly.
class ControllerScreen extends StatefulWidget {
  final MobileControllerEngine engine;
  final bool hapticEnabled;
  final VoidCallback? onOpenConnectionSettings;

  const ControllerScreen({
    super.key,
    required this.engine,
    this.hapticEnabled = true,
    this.onOpenConnectionSettings,
  });

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  final FocusNode _hardwareKeyFocusNode = FocusNode();
  bool _editMode = false;
  String? _selectedItemId;

  @override
  void initState() {
    super.initState();
    // Lock landscape orientation for controller gameplay
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _hardwareKeyFocusNode.dispose();
    super.dispose();
  }

  /// Intercepts physical Android Volume Up / Volume Down buttons as LT / RT triggers.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    HardwareKey? hwKey;
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      hwKey = HardwareKey.volumeUp;
    } else if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      hwKey = HardwareKey.volumeDown;
    }

    if (hwKey == null) return KeyEventResult.ignored;

    final isPressed = event is KeyDownEvent || event is KeyRepeatEvent;
    final consumed = widget.engine.handleHardwareKeyEvent(hwKey, isPressed);
    if (consumed) {
      if (event is KeyDownEvent && widget.hapticEnabled) {
        HapticFeedback.lightImpact();
      }
      setState(() {});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _togglePreset() {
    final nextProfile = widget.engine.profile.type == ControllerType.xbox
        ? ControllerProfile.playstationDefault()
        : ControllerProfile.xboxDefault();
    widget.engine.setProfile(nextProfile);
    setState(() {});
  }

  void _openAddComboDialog() {
    final selectedButtons = <GamepadButton>{
      GamepadButton.leftShoulder,
      GamepadButton.rightShoulder,
    };
    final labelCtrl = TextEditingController(text: 'COMBO');

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF161C28),
              title: const Text(
                'Tambah Tombol Combo',
                style: TextStyle(color: Colors.white),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: labelCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: 'Nama Tombol Combo (mis. ULT / RAGE)',
                        labelStyle: TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Pilih gabungan tombol yang ditekan bersamaan:',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final btn in GamepadButton.values)
                          FilterChip(
                            label: Text(widget.engine.profile.labelFor(btn)),
                            selected: selectedButtons.contains(btn),
                            selectedColor: const Color(0xFF00E5FF),
                            onSelected: (checked) {
                              setDialogState(() {
                                if (checked) {
                                  selectedButtons.add(btn);
                                } else if (selectedButtons.length > 1) {
                                  selectedButtons.remove(btn);
                                }
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Batal'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final id =
                        'combo_${DateTime.now().millisecondsSinceEpoch}';
                    final updatedLayout = widget.engine.layout.addComboButton(
                      id: id,
                      label: labelCtrl.text.trim().isEmpty
                          ? 'COMBO'
                          : labelCtrl.text.trim(),
                      comboActions: selectedButtons.toList(),
                      x: 0.50,
                      y: 0.50,
                      scale: 1.15,
                      colorHex: 0xFFFF4081,
                    );
                    widget.engine.setLayout(updatedLayout);
                    setState(() {
                      _selectedItemId = id;
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Simpan Combo'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.engine.layout;
    final profile = widget.engine.profile;
    final selectedItem = _selectedItemId != null
        ? layout.items.where((e) => e.id == _selectedItemId).firstOrNull
        : null;

    return Focus(
      focusNode: _hardwareKeyFocusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0E14),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;

            return Stack(
              children: [
                // 1. Top Status & Quick Action Bar
                Positioned(
                  top: 8,
                  left: 16,
                  right: 16,
                  child: _buildTopHud(profile),
                ),

                // 2. All Customizable Gamepad Elements (Joysticks, D-Pad, Single & Combo Buttons)
                for (final item in layout.items)
                  if (item.visible || _editMode)
                    _buildPositionedElement(
                      item: item,
                      canvasWidth: width,
                      canvasHeight: height,
                      profile: profile,
                    ),

                // 3. Bottom Layout Editor Inspector Panel (Resize Scale, Opacity, Delete Combo)
                if (_editMode && selectedItem != null)
                  Positioned(
                    bottom: 12,
                    left: width * 0.22,
                    right: width * 0.22,
                    child: _buildEditorInspector(selectedItem),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopHud(ControllerProfile profile) {
    final connected = widget.engine.isConnected;
    final rtt = widget.engine.lastRttMs.toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xD9151B26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _editMode ? const Color(0xFFFFAB00) : Colors.white12,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            connected ? Icons.wifi_tethering : Icons.portable_wifi_off,
            size: 16,
            color: connected ? const Color(0xFF00E676) : Colors.redAccent,
          ),
          const SizedBox(width: 6),
          Text(
            connected
                ? '${widget.engine.connectedServerName ?? "PC"} • ${rtt}ms'
                : 'OFFLINE',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 14),
          // Toggle Xbox / PlayStation Preset
          InkWell(
            onTap: _togglePreset,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Preset: ${profile.type == ControllerType.xbox ? "XBOX" : "PS"}',
                style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Toggle Layout Editor (Drag & Resize)
          InkWell(
            onTap: () => setState(() {
              _editMode = !_editMode;
              if (!_editMode) _selectedItemId = null;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _editMode
                    ? const Color(0xFFFFAB00)
                    : Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _editMode ? 'SELESAI EDIT' : 'EDIT LAYOUT / COMBO',
                style: TextStyle(
                  color: _editMode ? Colors.black : Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          if (_editMode) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: _openAddComboDialog,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4081),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '+ COMBO',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () {
                widget.engine.setLayout(
                  ControllerLayout.defaultLandscape(preset: profile.type),
                );
                setState(() => _selectedItemId = null);
              },
              child: const Text(
                'Reset',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
          ],
          if (widget.onOpenConnectionSettings != null) ...[
            const SizedBox(width: 12),
            InkWell(
              onTap: widget.onOpenConnectionSettings,
              child: const Icon(Icons.qr_code_scanner, size: 18, color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPositionedElement({
    required ButtonLayoutItem item,
    required double canvasWidth,
    required double canvasHeight,
    required ControllerProfile profile,
  }) {
    final baseSize = switch (item.type) {
      LayoutElementType.leftJoystick || LayoutElementType.rightJoystick => 145.0,
      LayoutElementType.dpad => 125.0,
      LayoutElementType.comboButton => 64.0,
      LayoutElementType.singleButton => 56.0,
    };

    final actualSize = baseSize * item.scale;
    final left = (item.x * canvasWidth) - (actualSize / 2);
    final top = (item.y * canvasHeight) - (actualSize / 2);
    final isSelected = _selectedItemId == item.id;

    Widget child;
    if (item.type == LayoutElementType.leftJoystick ||
        item.type == LayoutElementType.rightJoystick) {
      final isLeft = item.type == LayoutElementType.leftJoystick;
      child = VirtualJoystickWidget(
        size: actualSize,
        deadzone: profile.deadzone,
        label: item.label,
        editMode: _editMode,
        onStickChanged: (rx, ry) {
          widget.engine.handleJoystickMove(
            isLeftStick: isLeft,
            rawX: rx,
            rawY: ry,
          );
        },
      );
    } else {
      final isPressed = item.actions.isNotEmpty &&
          item.actions.every((b) => widget.engine.currentState.isPressed(b));
      final displayLabel = item.actions.length == 1
          ? profile.labelFor(item.actions.first)
          : item.label;

      child = Listener(
        onPointerDown: (_) {
          if (_editMode) {
            setState(() => _selectedItemId = item.id);
            return;
          }
          if (widget.hapticEnabled) {
            HapticFeedback.lightImpact();
          }
          widget.engine.handleLayoutItemTouch(item.id, true);
          setState(() {});
        },
        onPointerUp: (_) {
          if (_editMode) return;
          widget.engine.handleLayoutItemTouch(item.id, false);
          setState(() {});
        },
        onPointerCancel: (_) {
          if (_editMode) return;
          widget.engine.handleLayoutItemTouch(item.id, false);
          setState(() {});
        },
        child: Container(
          width: actualSize,
          height: actualSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: item.isCombo ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: item.isCombo ? BorderRadius.circular(16) : null,
            color: isPressed
                ? const Color(0xFF00E5FF).withValues(alpha: 0.85)
                : Color(item.colorHex ?? 0xFF1C2433)
                    .withValues(alpha: item.opacity),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFFFFAB00)
                  : (item.isCombo
                      ? const Color(0xFFFF4081)
                      : const Color(0xFF00E5FF).withValues(alpha: 0.55)),
              width: isSelected ? 2.5 : 1.5,
            ),
          ),
          child: Text(
            displayLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isPressed ? Colors.black : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: (13.0 * item.scale).clamp(10.0, 22.0),
            ),
          ),
        ),
      );
    }

    if (_editMode) {
      child = GestureDetector(
        onTap: () => setState(() => _selectedItemId = item.id),
        onPanUpdate: (details) {
          final nextX = item.x + (details.delta.dx / canvasWidth);
          final nextY = item.y + (details.delta.dy / canvasHeight);
          final updated = widget.engine.layout.updateItem(
            item.id,
            (curr) => curr.copyWith(x: nextX, y: nextY),
          );
          widget.engine.setLayout(updated);
          setState(() => _selectedItemId = item.id);
        },
        child: child,
      );
    }

    return Positioned(
      left: left,
      top: top,
      child: child,
    );
  }

  Widget _buildEditorInspector(ButtonLayoutItem selected) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xEE141A24),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFAB00)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'Edit: ${selected.label} (${selected.isCombo ? "Combo: ${selected.actions.map((a) => a.name).join("+")}" : selected.type.name})',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              if (selected.isCombo)
                TextButton.icon(
                  onPressed: () {
                    widget.engine.setLayout(
                      widget.engine.layout.removeItem(selected.id),
                    );
                    setState(() => _selectedItemId = null);
                  },
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: Colors.redAccent),
                  label: const Text('Hapus Combo',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                ),
            ],
          ),
          Row(
            children: [
              const Text('Ukuran:',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: selected.scale.clamp(0.5, 2.5),
                  min: 0.5,
                  max: 2.5,
                  activeColor: const Color(0xFF00E5FF),
                  onChanged: (val) {
                    widget.engine.setLayout(
                      widget.engine.layout.updateItem(
                        selected.id,
                        (curr) => curr.copyWith(scale: val),
                      ),
                    );
                    setState(() {});
                  },
                ),
              ),
              Text('${(selected.scale * 100).round()}%',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              const SizedBox(width: 16),
              const Text('Opacity:',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: selected.opacity.clamp(0.2, 1.0),
                  min: 0.2,
                  max: 1.0,
                  activeColor: const Color(0xFF00E5FF),
                  onChanged: (val) {
                    widget.engine.setLayout(
                      widget.engine.layout.updateItem(
                        selected.id,
                        (curr) => curr.copyWith(opacity: val),
                      ),
                    );
                    setState(() {});
                  },
                ),
              ),
              Text('${(selected.opacity * 100).round()}%',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
