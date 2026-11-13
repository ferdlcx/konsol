import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:ffi/ffi.dart';

import 'gamepad_provider.dart';

// Direct Pure-Dart FFI bindings to ViGEmClient.dll (if installed on Windows)
// OR built-in Windows user32.dll (keybd_event) — NO custom C++ wrapper DLL needed!
typedef _VigemAllocNative = ffi.Pointer<ffi.Void> Function();
typedef _VigemAllocDart = ffi.Pointer<ffi.Void> Function();

typedef _VigemConnectNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void> client);
typedef _VigemConnectDart = int Function(ffi.Pointer<ffi.Void> client);

typedef _VigemTargetAllocNative = ffi.Pointer<ffi.Void> Function();
typedef _VigemTargetAllocDart = ffi.Pointer<ffi.Void> Function();

typedef _VigemTargetAddNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
);
typedef _VigemTargetAddDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
);

/// XUSB_REPORT struct layout in C (12 bytes packed):
/// - USHORT wButtons (2 bytes)
/// - BYTE bLeftTrigger (1 byte)
/// - BYTE bRightTrigger (1 byte)
/// - SHORT sThumbLX (2 bytes)
/// - SHORT sThumbLY (2 bytes)
/// - SHORT sThumbRX (2 bytes)
/// - SHORT sThumbRY (2 bytes)
final class _XusbReport extends ffi.Struct {
  @ffi.Uint16()
  external int wButtons;

  @ffi.Uint8()
  external int bLeftTrigger;

  @ffi.Uint8()
  external int bRightTrigger;

  @ffi.Int16()
  external int sThumbLX;

  @ffi.Int16()
  external int sThumbLY;

  @ffi.Int16()
  external int sThumbRX;

  @ffi.Int16()
  external int sThumbRY;
}

typedef _VigemTargetX360UpdateNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  _XusbReport report,
);
typedef _VigemTargetX360UpdateDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  _XusbReport report,
);

typedef _VigemFreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef _VigemFreeDart = void Function(ffi.Pointer<ffi.Void> ptr);

// Windows built-in user32.dll fallback (`keybd_event`) so even a PC without
// any virtual gamepad driver installed can immediately receive inputs!
typedef _KeybdEventNative = ffi.Void Function(
  ffi.Uint8 bVk,
  ffi.Uint8 bScan,
  ffi.Uint32 dwFlags,
  ffi.IntPtr dwExtraInfo,
);
typedef _KeybdEventDart = void Function(
  int bVk,
  int bScan,
  int dwFlags,
  int dwExtraInfo,
);

/// 100% Pure-Dart Windows Gamepad Provider (Zero custom C++ `.dll` required!).
///
/// Strategy:
/// 1. Attempts to talk directly to the system's `ViGEmClient.dll` via `dart:ffi`.
/// 2. If `ViGEmBus` is not installed, gracefully operates in **Pure-Dart Live
///    Dashboard + Optional Win32 (`user32.dll`) Input Mode**, so the user only
///    ever needs **1 single `DartPad.exe` file**.
class PureDartWindowsGamepadProvider implements GamepadProvider {
  @override
  final ControllerType deviceType;

  final bool enableWin32KeyboardFallback;
  final void Function(ControllerState state)? onStateChanged;

  ffi.Pointer<ffi.Void>? _vigemClient;
  ffi.Pointer<ffi.Void>? _vigemTarget;
  _VigemTargetX360UpdateDart? _x360UpdateFn;
  _VigemFreeDart? _vigemDisconnectFn;
  _VigemFreeDart? _vigemFreeFn;
  _VigemFreeDart? _targetFreeFn;

  _KeybdEventDart? _keybdEventFn;

  bool _initialized = false;
  bool _hasNativeVigem = false;
  ControllerState _lastState = ControllerState.neutral;
  RumbleEvent? _pendingRumble;

  PureDartWindowsGamepadProvider({
    this.deviceType = ControllerType.xbox,
    this.enableWin32KeyboardFallback = false,
    this.onStateChanged,
  });

  @override
  bool get isInitialized => _initialized;

  bool get hasNativeVigemDriver => _hasNativeVigem;
  ControllerState get lastState => _lastState;

  void triggerRumble(RumbleEvent rumble) {
    _pendingRumble = rumble;
  }

  @override
  RumbleEvent? pollRumble() {
    final r = _pendingRumble;
    _pendingRumble = null;
    return r;
  }

  @override
  bool init() {
    _initialized = true;
    _lastState = ControllerState.neutral;

    if (!Platform.isWindows) {
      return true;
    }

    // 1. Try binding directly to system ViGEmClient.dll if present on the PC
    try {
      final vigemLib = ffi.DynamicLibrary.open('ViGEmClient.dll');
      final allocFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemAllocNative>>('vigem_alloc')
          .asFunction<_VigemAllocDart>();
      final connectFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemConnectNative>>('vigem_connect')
          .asFunction<_VigemConnectDart>();
      final targetAllocFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetAllocNative>>(
            'vigem_target_x360_alloc',
          )
          .asFunction<_VigemTargetAllocDart>();
      final targetAddFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetAddNative>>('vigem_target_add')
          .asFunction<_VigemTargetAddDart>();
      _x360UpdateFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetX360UpdateNative>>(
            'vigem_target_x360_update',
          )
          .asFunction<_VigemTargetX360UpdateDart>();
      _vigemDisconnectFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_disconnect')
          .asFunction<_VigemFreeDart>();
      _vigemFreeFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_free')
          .asFunction<_VigemFreeDart>();
      _targetFreeFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_target_free')
          .asFunction<_VigemFreeDart>();

      final client = allocFn();
      if (client != ffi.nullptr && connectFn(client) == 0x20000000) {
        final target = targetAllocFn();
        if (target != ffi.nullptr && targetAddFn(client, target) == 0x20000000) {
          _vigemClient = client;
          _vigemTarget = target;
          _hasNativeVigem = true;
        }
      }
    } catch (_) {
      _hasNativeVigem = false;
    }

    // 2. Bind built-in Windows user32.dll (always present on Windows 10/11)
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      _keybdEventFn = user32
          .lookup<ffi.NativeFunction<_KeybdEventNative>>('keybd_event')
          .asFunction<_KeybdEventDart>();
    } catch (_) {}

    return true;
  }

  @override
  bool update(ControllerState state) {
    if (!_initialized) return false;

    if (_hasNativeVigem &&
        _vigemClient != null &&
        _vigemTarget != null &&
        _x360UpdateFn != null) {
      final reportPtr = calloc<_XusbReport>();
      try {
        reportPtr.ref
          ..wButtons = _mapXusbButtons(state.buttonBitmask)
          ..bLeftTrigger = (state.leftTrigger.clamp(0.0, 1.0) * 255.0).round()
          ..bRightTrigger = (state.rightTrigger.clamp(0.0, 1.0) * 255.0).round()
          ..sThumbLX = (state.leftStick.x.clamp(-1.0, 1.0) * 32767.0).round()
          ..sThumbLY = (state.leftStick.y.clamp(-1.0, 1.0) * 32767.0).round()
          ..sThumbRX = (state.rightStick.x.clamp(-1.0, 1.0) * 32767.0).round()
          ..sThumbRY = (state.rightStick.y.clamp(-1.0, 1.0) * 32767.0).round();

        _x360UpdateFn!(_vigemClient!, _vigemTarget!, reportPtr.ref);
      } finally {
        calloc.free(reportPtr);
      }
    } else if (enableWin32KeyboardFallback && _keybdEventFn != null) {
      _syncWin32KeyboardFallback(_lastState, state);
    }

    _lastState = state;
    onStateChanged?.call(state);
    return true;
  }

  @override
  bool reset() {
    return update(ControllerState.neutral);
  }

  @override
  void dispose() {
    if (_hasNativeVigem && _vigemClient != null) {
      reset();
      if (_vigemTarget != null) {
        _targetFreeFn?.call(_vigemTarget!);
        _vigemTarget = null;
      }
      _vigemDisconnectFn?.call(_vigemClient!);
      _vigemFreeFn?.call(_vigemClient!);
      _vigemClient = null;
      _hasNativeVigem = false;
    }
    _initialized = false;
  }

  static int _mapXusbButtons(int mask) {
    var wButtons = 0;
    if ((mask & (1 << 0)) != 0) wButtons |= 0x1000; // A (south)
    if ((mask & (1 << 1)) != 0) wButtons |= 0x2000; // B (east)
    if ((mask & (1 << 2)) != 0) wButtons |= 0x4000; // X (west)
    if ((mask & (1 << 3)) != 0) wButtons |= 0x8000; // Y (north)
    if ((mask & (1 << 4)) != 0) wButtons |= 0x0100; // LB
    if ((mask & (1 << 5)) != 0) wButtons |= 0x0200; // RB
    if ((mask & (1 << 8)) != 0) wButtons |= 0x0001; // D-Pad Up
    if ((mask & (1 << 9)) != 0) wButtons |= 0x0002; // D-Pad Down
    if ((mask & (1 << 10)) != 0) wButtons |= 0x0004; // D-Pad Left
    if ((mask & (1 << 11)) != 0) wButtons |= 0x0008; // D-Pad Right
    if ((mask & (1 << 12)) != 0) wButtons |= 0x0010; // Start
    if ((mask & (1 << 13)) != 0) wButtons |= 0x0020; // Back
    if ((mask & (1 << 14)) != 0) wButtons |= 0x0400; // Guide
    if ((mask & (1 << 15)) != 0) wButtons |= 0x0040; // LS
    if ((mask & (1 << 16)) != 0) wButtons |= 0x0080; // RS
    return wButtons;
  }

  void _syncWin32KeyboardFallback(ControllerState prev, ControllerState next) {
    const keyMap = <GamepadButton, int>{
      GamepadButton.south: 0x20, // Space
      GamepadButton.east: 0x43, // C
      GamepadButton.west: 0x52, // R
      GamepadButton.north: 0x46, // F
      GamepadButton.leftShoulder: 0x51, // Q
      GamepadButton.rightShoulder: 0x45, // E
      GamepadButton.dpadUp: 0x26, // Up Arrow
      GamepadButton.dpadDown: 0x28, // Down Arrow
      GamepadButton.dpadLeft: 0x25, // Left Arrow
      GamepadButton.dpadRight: 0x27, // Right Arrow
      GamepadButton.start: 0x0D, // Enter
      GamepadButton.select: 0x09, // Tab
    };

    for (final entry in keyMap.entries) {
      final wasPressed = prev.isPressed(entry.key);
      final isNowPressed = next.isPressed(entry.key);
      if (wasPressed != isNowPressed) {
        // 0 = KeyDown, 2 = KEYEVENTF_KEYUP
        _keybdEventFn!(entry.value, 0, isNowPressed ? 0 : 2, 0);
      }
    }
  }
}
