import 'dart:math' as math;
import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/dpad_cross_widget.dart';
import '../widgets/virtual_joystick.dart';

/// Responsive, Anti-Overlap Xbox-Style Controller & Layout/Combo Editor Screen.
class ControllerScreen extends StatefulWidget {
  final MobileControllerEngine engine;
  final VoidCallback onBackToDashboard;
  final VoidCallback onSettingsChanged;

  const ControllerScreen({
    super.key,
    required this.engine,
    required this.onBackToDashboard,
    required this.onSettingsChanged,
  });

  /// Shared Settings, Theme, Global Scale, & Release Info dialog callable from
  /// both DashboardScreen and ControllerScreen.
  static Future<void> showSettingsDialog({
    required BuildContext context,
    required MobileControllerEngine engine,
    required VoidCallback onChanged,
  }) async {
    var settings = engine.settings;
    var deadzone = engine.profile.deadzone;
    var sensitivity = engine.profile.sensitivity;
    var volTriggers = engine.profile.enableVolumeKeysAsTriggers;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final theme = settings.themePreset;

            void persistAll() {
              final curr = engine.profile;
              engine.setProfile(
                ControllerProfile(
                  id: curr.id,
                  name: curr.name,
                  type: curr.type,
                  deadzone: deadzone,
                  sensitivity: sensitivity,
                  buttonLabels: curr.buttonLabels,
                  enableVolumeKeysAsTriggers: volTriggers,
                  hardwareKeyBindings: curr.hardwareKeyBindings,
                ),
              );
              engine.updateSettings(settings);
              onChanged();
            }

            return AlertDialog(
              backgroundColor: Color(theme.panelHex),
              title: Row(
                children: [
                  Icon(Icons.settings, color: Color(theme.accentHex)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Settings, Theme & Release Info',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Tema Tampilan (Theme):',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final preset in DartPadThemePreset.values)
                            ChoiceChip(
                              label: Text(preset.name,
                                  style: const TextStyle(fontSize: 11)),
                              selected: settings.themeId == preset.id,
                              selectedColor: Color(preset.primaryHex),
                              onSelected: (_) {
                                setDialogState(() {
                                  settings =
                                      settings.copyWith(themeId: preset.id);
                                });
                                persistAll();
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const SizedBox(
                            width: 145,
                            child: Text('Ukuran Global Tombol:',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ),
                          Expanded(
                            child: Slider(
                              value:
                                  settings.globalScale.clamp(0.6, 1.5).toDouble(),
                              min: 0.6,
                              max: 1.5,
                              activeColor: Color(theme.accentHex),
                              onChanged: (val) {
                                setDialogState(() {
                                  settings =
                                      settings.copyWith(globalScale: val);
                                });
                                persistAll();
                              },
                            ),
                          ),
                          Text('${(settings.globalScale * 100).round()}%',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(
                            width: 145,
                            child: Text('Deadzone Analog:',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ),
                          Expanded(
                            child: Slider(
                              value: deadzone.clamp(0.0, 0.35).toDouble(),
                              min: 0.0,
                              max: 0.35,
                              activeColor: Color(theme.accentHex),
                              onChanged: (val) {
                                setDialogState(() => deadzone = val);
                                persistAll();
                              },
                            ),
                          ),
                          Text('${(deadzone * 100).round()}%',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(
                            width: 145,
                            child: Text('Sensitivity Analog:',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ),
                          Expanded(
                            child: Slider(
                              value: sensitivity.clamp(0.5, 2.0).toDouble(),
                              min: 0.5,
                              max: 2.0,
                              activeColor: Color(theme.accentHex),
                              onChanged: (val) {
                                setDialogState(() => sensitivity = val);
                                persistAll();
                              },
                            ),
                          ),
                          Text('${(sensitivity * 100).round()}%',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12)),
                        ],
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Auto-Pair & Auto-Reconnect (Wi-Fi & USB Tethering)',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        subtitle: const Text(
                          'Otomatis cari PC & simpan koneksi walaupun HP/PC dimatikan',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                        value: settings.autoPairEnabled,
                        activeColor: Color(theme.accentHex),
                        onChanged: (val) {
                          setDialogState(() {
                            settings = settings.copyWith(autoPairEnabled: val);
                          });
                          persistAll();
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Tombol Volume HP sebagai Trigger (LT / RT)',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        value: volTriggers,
                        activeColor: Color(theme.accentHex),
                        onChanged: (val) {
                          setDialogState(() => volTriggers = val);
                          persistAll();
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Getar / Haptic & Force Feedback (Rumble)',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        value: settings.hapticFeedback,
                        activeColor: Color(theme.accentHex),
                        onChanged: (val) {
                          setDialogState(() {
                            settings = settings.copyWith(hapticFeedback: val);
                          });
                          persistAll();
                        },
                      ),
                      const Divider(color: Colors.white24),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Release Info — DartPad v${DartPadAppSettings.appVersion}',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '• Layout Bawaan: Xbox Big Controls (LS, XYAB, LT/LB/RB/RT 2x Lebih Besar)\n'
                              '• Combo Macro: Instan & Urutan Milidetik ((1) X→Y→A→A)\n'
                              '• Scan QR Kamera Google ML Kit + Subnet Sweep Wi-Fi LAN & USB\n'
                              '• Release & Update: github.com/ferdlcx/konsol/releases',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Tutup & Simpan'),
                ),
              ],
            );
          },
        );
      },
    );
  }

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
      if (event is KeyDownEvent && widget.engine.settings.hapticFeedback) {
        HapticFeedback.lightImpact();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _togglePreset() {
    final curr = widget.engine.profile;
    final nextType = curr.type == ControllerType.xbox
        ? ControllerType.playstation
        : ControllerType.xbox;
    final nextProfile = ControllerProfile(
      id: nextType == ControllerType.xbox ? 'xbox_default' : 'ps_default',
      name:
          nextType == ControllerType.xbox ? 'Xbox Default' : 'PlayStation Default',
      type: nextType,
      deadzone: curr.deadzone,
      sensitivity: curr.sensitivity,
      enableVolumeKeysAsTriggers: curr.enableVolumeKeysAsTriggers,
      hardwareKeyBindings: curr.hardwareKeyBindings,
      buttonLabels: {
        for (final b in GamepadButton.values) b: nextType.labelFor(b),
      },
    );
    widget.engine.setProfile(nextProfile);
    setState(() {});
  }

  /// Shows the Top-Center Close / Dashboard / Quick Menu dialog so pressing back or
  /// the center-top close button cleanly returns to Dashboard Mobile without killing APK.
  void _openCloseMenuDialog() {
    final theme = widget.engine.settings.themePreset;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Color(theme.panelHex),
          title: const Text(
            'Menu Konsol DartPad',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    Icon(Icons.dashboard, color: Color(theme.accentHex)),
                title: const Text('Kembali ke Dashboard Mobile',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
                subtitle: Text(
                  widget.engine.isConnected
                      ? 'Terhubung ke ${widget.engine.connectedServerName}'
                      : 'Scan QR Kamera, Auto-Pair Wi-Fi / USB, Cek Update',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.engine.releaseAllInputs();
                  widget.onBackToDashboard();
                },
              ),
              ListTile(
                leading: Icon(Icons.tune, color: Color(theme.accentHex)),
                title: const Text(
                    'Pengaturan (Theme, Besar-Kecil, Release Info)',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openSettingsAndReleaseInfoDialog();
                },
              ),
              const Divider(color: Colors.white12),
              ListTile(
                leading:
                    const Icon(Icons.exit_to_app, color: Colors.redAccent),
                title: const Text('Keluar Total dari APK',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  widget.engine.releaseAllInputs();
                  SystemNavigator.pop();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Lanjut Bermain'),
            ),
          ],
        );
      },
    );
  }

  void _openSettingsAndReleaseInfoDialog() {
    ControllerScreen.showSettingsDialog(
      context: context,
      engine: widget.engine,
      onChanged: () {
        widget.onSettingsChanged();
        if (mounted) setState(() {});
      },
    );
  }

  /// Opens the Combo Macro Builder supporting BOTH Instant Combos (`LB + RB`)
  /// and Ordered Millisecond Sequence Macros (`(1)` `X -> Y -> A -> A`).
  void _openAddComboDialog() {
    final sequenceList = <GamepadButton>[
      GamepadButton.west, // X
      GamepadButton.north, // Y
      GamepadButton.south, // A
      GamepadButton.south, // A
    ];
    var mode = ComboExecutionMode.sequence;
    var stepDelayMs = 75;
    final nextNum = widget.engine.layout.items
            .where((e) => e.type == LayoutElementType.comboButton)
            .length +
        1;
    final labelCtrl = TextEditingController(text: '($nextNum)');
    final theme = widget.engine.settings.themePreset;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final previewStr = sequenceList.isEmpty
                ? '(kosong - tap tombol di bawah untuk menambah)'
                : sequenceList
                    .map((b) => widget.engine.profile.labelFor(b))
                    .join(mode == ComboExecutionMode.sequence ? ' → ' : ' + ');

            return AlertDialog(
              backgroundColor: Color(theme.panelHex),
              title: const Text(
                'Buat Tombol Combo / Macro Urutan (ms)',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 110,
                            child: TextField(
                              controller: labelCtrl,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Label (mis. (1))',
                                labelStyle:
                                    TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: SegmentedButton<ComboExecutionMode>(
                              segments: const [
                                ButtonSegment(
                                  value: ComboExecutionMode.sequence,
                                  label: Text('Urutan (ms)',
                                      style: TextStyle(fontSize: 11)),
                                ),
                                ButtonSegment(
                                  value: ComboExecutionMode.simultaneous,
                                  label: Text('Instan (Bersamaan)',
                                      style: TextStyle(fontSize: 11)),
                                ),
                              ],
                              selected: {mode},
                              onSelectionChanged: (s) {
                                setDialogState(() => mode = s.first);
                              },
                            ),
                          ),
                        ],
                      ),
                      if (mode == ComboExecutionMode.sequence) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Text('Jeda per tombol:',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            Expanded(
                              child: Slider(
                                value: stepDelayMs.toDouble(),
                                min: 25,
                                max: 400,
                                divisions: 15,
                                activeColor: Color(theme.accentHex),
                                onChanged: (v) {
                                  setDialogState(() => stepDelayMs = v.round());
                                },
                              ),
                            ),
                            Text('$stepDelayMs ms',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black38,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Color(theme.accentHex)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Isi Combo: $previewStr',
                                style: TextStyle(
                                  color: Color(theme.accentHex),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Hapus langkah terakhir',
                              onPressed: sequenceList.isEmpty
                                  ? null
                                  : () => setDialogState(
                                      () => sequenceList.removeLast()),
                              icon: const Icon(Icons.backspace_outlined,
                                  size: 18, color: Colors.white70),
                            ),
                            IconButton(
                              tooltip: 'Reset urutan',
                              onPressed: sequenceList.isEmpty
                                  ? null
                                  : () =>
                                      setDialogState(() => sequenceList.clear()),
                              icon: const Icon(Icons.clear_all,
                                  size: 18, color: Colors.redAccent),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap tombol untuk menambahkan ke urutan (bisa berulang, mis. X lalu Y lalu A lalu A):',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final btn in GamepadButton.values)
                            ActionChip(
                              backgroundColor: const Color(0xFF222C3C),
                              label: Text(
                                '+ ${widget.engine.profile.labelFor(btn)}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                              onPressed: () {
                                setDialogState(() => sequenceList.add(btn));
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Batal'),
                ),
                ElevatedButton(
                  onPressed: sequenceList.isEmpty
                      ? null
                      : () {
                          final id =
                              'combo_${DateTime.now().millisecondsSinceEpoch}';
                          final updatedLayout =
                              widget.engine.layout.addComboButton(
                            id: id,
                            label: labelCtrl.text.trim().isEmpty
                                ? '($nextNum)'
                                : labelCtrl.text.trim(),
                            comboActions: List<GamepadButton>.from(sequenceList),
                            comboMode: mode,
                            stepDelayMs: stepDelayMs,
                            x: 0.50,
                            y: 0.65,
                            scale: 1.0,
                            colorHex: 0xFFFF4081,
                          );
                          widget.engine.setLayout(updatedLayout);
                          setState(() => _selectedItemId = id);
                          Navigator.of(ctx).pop();
                        },
                  child: const Text('Simpan Tombol Combo'),
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
    final settings = widget.engine.settings;
    final theme = settings.themePreset;
    final selectedItem = _selectedItemId != null
        ? layout.items.where((e) => e.id == _selectedItemId).firstOrNull
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editMode) {
          setState(() {
            _editMode = false;
            _selectedItemId = null;
          });
        } else {
          _openCloseMenuDialog();
        }
      },
      child: Focus(
        focusNode: _hardwareKeyFocusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Scaffold(
          backgroundColor: Color(theme.bgHex),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final height = constraints.maxHeight;
                final shortestSide = math.min(width, height);

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Subtle Xbox ergonomic grip background arcs
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _ControllerGripBackgroundPainter(
                            primaryColor: Color(theme.primaryHex),
                          ),
                        ),
                      ),
                    ),

                    // 1. All Gamepad Controls (Joysticks, Cross D-Pad, Shoulders, Diamond ABXY, Combos)
                    for (final item in layout.items)
                      if (item.visible || _editMode)
                        _buildResponsiveElement(
                          item: item,
                          canvasWidth: width,
                          canvasHeight: height,
                          shortestSide: shortestSide,
                          globalScale: settings.globalScale,
                          profile: profile,
                          theme: theme,
                        ),

                    // 2. Compact Top-Center Control Bar (with Close/Exit button in the top middle!)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _buildTopCenterHud(profile, theme),
                      ),
                    ),

                    // 3. Bottom Layout Editor Inspector Panel
                    if (_editMode && selectedItem != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildEditorInspector(selectedItem, theme),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopCenterHud(
    ControllerProfile profile,
    DartPadThemePreset theme,
  ) {
    final connected = widget.engine.isConnected;
    final rtt = widget.engine.lastRttMs.toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Color(theme.panelHex).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: _editMode
              ? const Color(0xFFFFAB00)
              : Color(theme.accentHex).withValues(alpha: 0.45),
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Connection / Dashboard Pill
          InkWell(
            onTap: () {
              widget.engine.releaseAllInputs();
              widget.onBackToDashboard();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected ? Icons.wifi_tethering : Icons.dashboard_rounded,
                  size: 14,
                  color: connected
                      ? const Color(0xFF00E676)
                      : Colors.amberAccent,
                ),
                const SizedBox(width: 4),
                Text(
                  connected
                      ? '${widget.engine.connectedServerName ?? "PC"} (${rtt}ms)'
                      : 'DASHBOARD',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Preset Xbox / PS Toggle
          _hudChip(
            label: profile.type == ControllerType.xbox ? 'XBOX' : 'PS',
            color: Color(theme.primaryHex),
            onTap: _togglePreset,
          ),
          const SizedBox(width: 6),

          // Edit Layout / Combo Toggle
          _hudChip(
            label: _editMode ? 'SELESAI' : 'EDIT / COMBO',
            color: _editMode
                ? const Color(0xFFFFAB00)
                : const Color(0xFF253042),
            textColor: _editMode ? Colors.black : Colors.white,
            onTap: () => setState(() {
              _editMode = !_editMode;
              if (!_editMode) _selectedItemId = null;
            }),
          ),

          if (_editMode) ...[
            const SizedBox(width: 6),
            _hudChip(
              label: '+ COMBO',
              color: const Color(0xFFFF4081),
              onTap: _openAddComboDialog,
            ),
            const SizedBox(width: 6),
            _hudChip(
              label: 'RESET',
              color: Colors.white12,
              onTap: () {
                widget.engine.setLayout(
                  ControllerLayout.defaultLandscape(preset: profile.type),
                );
                setState(() => _selectedItemId = null);
              },
            ),
          ],

          const SizedBox(width: 6),
          // Settings & Theme Button
          InkWell(
            onTap: _openSettingsAndReleaseInfoDialog,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.settings, size: 17, color: Colors.white70),
            ),
          ),

          const SizedBox(width: 6),
          // Prominent Top-Center CLOSE / EXIT Button
          InkWell(
            onTap: _openCloseMenuDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, size: 13, color: Colors.white),
                  SizedBox(width: 3),
                  Text(
                    'CLOSE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hudChip({
    required String label,
    required Color color,
    Color textColor = Colors.white,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildResponsiveElement({
    required ButtonLayoutItem item,
    required double canvasWidth,
    required double canvasHeight,
    required double shortestSide,
    required double globalScale,
    required ControllerProfile profile,
    required DartPadThemePreset theme,
  }) {
    final isBumperOrTrigger = item.id == 'btn_lt' ||
        item.id == 'btn_lb' ||
        item.id == 'btn_rb' ||
        item.id == 'btn_rt';

    final baseDimension = switch (item.type) {
      LayoutElementType.leftJoystick ||
      LayoutElementType.rightJoystick =>
        shortestSide * 0.29,
      LayoutElementType.dpad => shortestSide * 0.26,
      LayoutElementType.comboButton => shortestSide * 0.13,
      LayoutElementType.singleButton => shortestSide * 0.13,
    };

    final double scaledSize = (baseDimension * globalScale * item.scale)
        .clamp(28.0, shortestSide * 0.58)
        .toDouble();
    final double elemWidth = isBumperOrTrigger
        ? scaledSize * 1.48
        : (item.isCombo ? scaledSize * 1.35 : scaledSize);
    final double elemHeight =
        isBumperOrTrigger ? scaledSize * 0.78 : scaledSize;

    // Clamp strictly inside screen boundaries so nothing EVER overflows or collides with edges
    final double left = ((item.x * canvasWidth) - (elemWidth / 2))
        .clamp(4.0, math.max(4.0, canvasWidth - elemWidth - 4.0))
        .toDouble();
    final double top = ((item.y * canvasHeight) - (elemHeight / 2))
        .clamp(4.0, math.max(4.0, canvasHeight - elemHeight - 4.0))
        .toDouble();

    final isSelected = _selectedItemId == item.id;

    Widget child;
    if (item.type == LayoutElementType.leftJoystick ||
        item.type == LayoutElementType.rightJoystick) {
      final isLeft = item.type == LayoutElementType.leftJoystick;
      child = VirtualJoystickWidget(
        size: scaledSize,
        deadzone: profile.deadzone,
        accentColor: Color(theme.accentHex),
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
    } else if (item.type == LayoutElementType.dpad) {
      child = DpadCrossWidget(
        size: scaledSize,
        accentColor: Color(theme.accentHex),
        editMode: _editMode,
        hapticEnabled: widget.engine.settings.hapticFeedback,
        onDirectionsChanged: (dirs) {
          widget.engine.handleDirectButtonSet('dpad_cross', dirs);
        },
      );
    } else {
      final displayLabel = item.actions.length == 1 && !item.isCombo
          ? profile.labelFor(item.actions.first)
          : item.label;
      final subLabel = item.isCombo ? item.describeCombo(profile.type) : null;

      child = _GamepadActionButton(
        width: elemWidth,
        height: elemHeight,
        label: displayLabel,
        subLabel: subLabel,
        isBumper: isBumperOrTrigger,
        isCombo: item.isCombo,
        isSelected: isSelected,
        editMode: _editMode,
        opacity: item.opacity,
        fillColor: Color(item.colorHex ?? theme.panelHex),
        accentColor: Color(theme.accentHex),
        hapticEnabled: widget.engine.settings.hapticFeedback,
        onSelectInEditMode: () => setState(() => _selectedItemId = item.id),
        onPressedChanged: (pressed) {
          widget.engine.handleLayoutItemTouch(item.id, pressed);
        },
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

  Widget _buildEditorInspector(
    ButtonLayoutItem selected,
    DartPadThemePreset theme,
  ) {
    return Container(
      width: 480,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Color(theme.panelHex).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFAB00)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Edit: ${selected.label} ${selected.isCombo ? "[${selected.describeCombo(widget.engine.profile.type)}]" : ""}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              if (selected.isCombo)
                TextButton.icon(
                  onPressed: () {
                    widget.engine.setLayout(
                      widget.engine.layout.removeItem(selected.id),
                    );
                    setState(() => _selectedItemId = null);
                  },
                  icon: const Icon(Icons.delete_outline,
                      size: 15, color: Colors.redAccent),
                  label: const Text('Hapus',
                      style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                ),
            ],
          ),
          Row(
            children: [
              const Text('Besar/Kecil:',
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: selected.scale.clamp(0.5, 2.2).toDouble(),
                  min: 0.5,
                  max: 2.2,
                  activeColor: Color(theme.accentHex),
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
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
              const SizedBox(width: 12),
              const Text('Opacity:',
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: selected.opacity.clamp(0.2, 1.0).toDouble(),
                  min: 0.2,
                  max: 1.0,
                  activeColor: Color(theme.accentHex),
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
                  style: const TextStyle(color: Colors.white, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Self-contained button widget that manages its own pressed highlight state
/// locally so touching buttons never triggers full-screen rebuild lag.
class _GamepadActionButton extends StatefulWidget {
  final double width;
  final double height;
  final String label;
  final String? subLabel;
  final bool isBumper;
  final bool isCombo;
  final bool isSelected;
  final bool editMode;
  final double opacity;
  final Color fillColor;
  final Color accentColor;
  final bool hapticEnabled;
  final VoidCallback onSelectInEditMode;
  final ValueChanged<bool> onPressedChanged;

  const _GamepadActionButton({
    required this.width,
    required this.height,
    required this.label,
    this.subLabel,
    required this.isBumper,
    required this.isCombo,
    required this.isSelected,
    required this.editMode,
    required this.opacity,
    required this.fillColor,
    required this.accentColor,
    required this.hapticEnabled,
    required this.onSelectInEditMode,
    required this.onPressedChanged,
  });

  @override
  State<_GamepadActionButton> createState() => _GamepadActionButtonState();
}

class _GamepadActionButtonState extends State<_GamepadActionButton> {
  bool _isPressed = false;

  void _setPressed(bool next) {
    if (widget.editMode) {
      if (next) widget.onSelectInEditMode();
      return;
    }
    if (_isPressed == next) return;
    if (next && widget.hapticEnabled) {
      HapticFeedback.lightImpact();
    }
    setState(() => _isPressed = next);
    widget.onPressedChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final isCircular = !widget.isBumper && !widget.isCombo;

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: Container(
        width: widget.width,
        height: widget.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          shape: isCircular ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isCircular ? null : BorderRadius.circular(14),
          color: _isPressed
              ? widget.accentColor
              : widget.fillColor.withValues(alpha: widget.opacity),
          boxShadow: _isPressed
              ? [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.55),
                    blurRadius: 12,
                  ),
                ]
              : null,
          border: Border.all(
            color: widget.isSelected
                ? const Color(0xFFFFAB00)
                : (_isPressed
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.35)),
            width: widget.isSelected ? 2.5 : 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _isPressed ? Colors.black : Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: (widget.height * 0.34).clamp(10.0, 20.0).toDouble(),
              ),
            ),
            if (widget.subLabel != null)
              Text(
                widget.subLabel!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _isPressed ? Colors.black87 : Colors.white70,
                  fontSize: (widget.height * 0.17).clamp(7.5, 10.5).toDouble(),
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ControllerGripBackgroundPainter extends CustomPainter {
  final Color primaryColor;

  const _ControllerGripBackgroundPainter({required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = primaryColor.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Subtle Xbox controller contour lines on left and right sides
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.55),
      size.height * 0.42,
      paint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.55),
      size.height * 0.42,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ControllerGripBackgroundPainter oldDelegate) {
    return oldDelegate.primaryColor != primaryColor;
  }
}
