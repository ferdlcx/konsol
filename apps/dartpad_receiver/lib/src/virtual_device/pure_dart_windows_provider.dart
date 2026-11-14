import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:ffi/ffi.dart';

import 'gamepad_provider.dart';

// Pure-Dart FFI bindings directly to official ViGEmClient.dll (Xbox 360 + DualShock 4)
// and built-in Windows user32.dll (optional keyboard fallback).
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

typedef _VigemTargetRemoveNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
);
typedef _VigemTargetRemoveDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
);

/// XUSB_REPORT struct layout in C (12 bytes):
/// USHORT wButtons, BYTE bLeftTrigger, BYTE bRightTrigger, SHORT sThumbLX..RY
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

/// DS4_REPORT struct layout in C (9 bytes + alignment = 10 bytes):
/// BYTE bThumbLX..RY, USHORT wButtons, BYTE bSpecial, BYTE bTriggerL, BYTE bTriggerR
final class _Ds4Report extends ffi.Struct {
  @ffi.Uint8()
  external int bThumbLX;

  @ffi.Uint8()
  external int bThumbLY;

  @ffi.Uint8()
  external int bThumbRX;

  @ffi.Uint8()
  external int bThumbRY;

  @ffi.Uint16()
  external int wButtons;

  @ffi.Uint8()
  external int bSpecial;

  @ffi.Uint8()
  external int bTriggerL;

  @ffi.Uint8()
  external int bTriggerR;
}

final class _XusbOutputData extends ffi.Struct {
  @ffi.Uint8()
  external int largeMotor;

  @ffi.Uint8()
  external int smallMotor;

  @ffi.Uint8()
  external int ledNumber;
}

final class _Ds4OutputData extends ffi.Struct {
  @ffi.Uint8()
  external int largeMotor;

  @ffi.Uint8()
  external int smallMotor;

  @ffi.Uint8()
  external int red;

  @ffi.Uint8()
  external int green;

  @ffi.Uint8()
  external int blue;
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

typedef _VigemTargetDs4UpdateNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  _Ds4Report report,
);
typedef _VigemTargetDs4UpdateDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  _Ds4Report report,
);

typedef _VigemX360GetUserIndexNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<ffi.Uint32> index,
);
typedef _VigemX360GetUserIndexDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<ffi.Uint32> index,
);

typedef _VigemX360GetOutputNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<_XusbOutputData> output,
);
typedef _VigemX360GetOutputDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<_XusbOutputData> output,
);

typedef _VigemDs4GetOutputNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<_Ds4OutputData> output,
);
typedef _VigemDs4GetOutputDart = int Function(
  ffi.Pointer<ffi.Void> client,
  ffi.Pointer<ffi.Void> target,
  ffi.Pointer<_Ds4OutputData> output,
);

typedef _VigemFreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef _VigemFreeDart = void Function(ffi.Pointer<ffi.Void> ptr);

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

/// Pure-Dart Windows Virtual Gamepad Provider (`Xbox 360` + `Sony DualShock 4`).
///
/// Uses direct `dart:ffi` bindings to official `ViGEmClient.dll` + `ViGEmBus` kernel
/// driver so Windows games (SpartanPort, Steam, FIFA, etc.) recognize DartPad as
/// an authentic XInput Xbox 360 or Sony DualShock 4 controller.
class PureDartWindowsGamepadProvider implements GamepadProvider {
  static const int _vigemErrorNone = 0x20000000;
  static const int _vigemErrorBusNotFound = 0xE0000001;

  ControllerType _deviceType;
  bool enableWin32KeyboardFallback;
  final void Function(ControllerState state)? onStateChanged;

  ffi.Pointer<ffi.Void>? _vigemClient;
  ffi.Pointer<ffi.Void>? _vigemTarget;
  _VigemAllocDart? _allocFn;
  _VigemConnectDart? _connectFn;
  _VigemTargetAllocDart? _x360AllocFn;
  _VigemTargetAllocDart? _ds4AllocFn;
  _VigemTargetAddDart? _targetAddFn;
  _VigemTargetRemoveDart? _targetRemoveFn;
  _VigemTargetX360UpdateDart? _x360UpdateFn;
  _VigemTargetDs4UpdateDart? _ds4UpdateFn;
  _VigemX360GetUserIndexDart? _x360GetUserIndexFn;
  _VigemX360GetOutputDart? _x360GetOutputFn;
  _VigemDs4GetOutputDart? _ds4GetOutputFn;
  _VigemFreeDart? _vigemDisconnectFn;
  _VigemFreeDart? _vigemFreeFn;
  _VigemFreeDart? _targetFreeFn;

  _KeybdEventDart? _keybdEventFn;

  bool _initialized = false;
  bool _hasVigemDll = false;
  bool _hasNativeVigem = false;
  int _lastVigemError = 0;
  String _statusMessage = 'Belum diinisialisasi';
  ControllerState _lastState = ControllerState.neutral;
  RumbleEvent? _pendingRumble;
  int _lastLargeMotor = 0;
  int _lastSmallMotor = 0;

  PureDartWindowsGamepadProvider({
    ControllerType deviceType = ControllerType.xbox,
    this.enableWin32KeyboardFallback = false,
    this.onStateChanged,
  }) : _deviceType = deviceType;

  @override
  ControllerType get deviceType => _deviceType;

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isHardwareDriverActive => _hasNativeVigem;

  bool get hasVigemDll => _hasVigemDll;
  bool get hasNativeVigemDriver => _hasNativeVigem;
  int get lastVigemError => _lastVigemError;
  ControllerState get lastState => _lastState;

  @override
  String get driverStatusSummary => _statusMessage;

  void triggerRumble(RumbleEvent rumble) {
    _pendingRumble = rumble;
  }

  @override
  RumbleEvent? pollRumble() {
    if (_pendingRumble != null) {
      final r = _pendingRumble;
      _pendingRumble = null;
      return r;
    }

    if (!_hasNativeVigem || _vigemClient == null || _vigemTarget == null) {
      return null;
    }

    try {
      int large = 0;
      int small = 0;
      if (_deviceType == ControllerType.xbox && _x360GetOutputFn != null) {
        final outPtr = calloc<_XusbOutputData>();
        try {
          final res = _x360GetOutputFn!(_vigemClient!, _vigemTarget!, outPtr);
          if (res == _vigemErrorNone) {
            large = outPtr.ref.largeMotor;
            small = outPtr.ref.smallMotor;
          }
        } finally {
          calloc.free(outPtr);
        }
      } else if (_deviceType == ControllerType.playstation &&
          _ds4GetOutputFn != null) {
        final outPtr = calloc<_Ds4OutputData>();
        try {
          final res = _ds4GetOutputFn!(_vigemClient!, _vigemTarget!, outPtr);
          if (res == _vigemErrorNone) {
            large = outPtr.ref.largeMotor;
            small = outPtr.ref.smallMotor;
          }
        } finally {
          calloc.free(outPtr);
        }
      }

      if (large != _lastLargeMotor || small != _lastSmallMotor) {
        _lastLargeMotor = large;
        _lastSmallMotor = small;
        if (large > 4 || small > 4) {
          return RumbleEvent(
            largeMotor: large / 255.0,
            smallMotor: small / 255.0,
            durationMs: 140,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// Inspects a Windows DLL's PE header without loading/locking it in memory.
  /// Returns `true` only if the DLL has a non-empty PE Export Directory
  /// (rejects stub/empty DLLs such as v0.3.0's 10KB build without exports).
  static bool isValidPeExportDll(File file) {
    try {
      if (!file.existsSync()) return false;
      final bytes = file.readAsBytesSync();
      if (bytes.length < 0x100) return false;
      // Check DOS signature 'MZ'
      if (bytes[0] != 0x4D || bytes[1] != 0x5A) return false;
      final bd = ByteData.sublistView(bytes);
      final lfanew = bd.getUint32(0x3C, Endian.little);
      if (lfanew + 0xA8 > bytes.length) return false;
      // Check 'PE\0\0'
      if (bytes[lfanew] != 0x50 ||
          bytes[lfanew + 1] != 0x45 ||
          bytes[lfanew + 2] != 0x00 ||
          bytes[lfanew + 3] != 0x00) {
        return false;
      }
      final optHeaderStart = lfanew + 24;
      final magic = bd.getUint16(optHeaderStart, Endian.little);
      // PE32+ (64-bit) = 0x20B (DataDirectory starts at +112), PE32 = 0x10B (+96)
      final dataDirOffset = magic == 0x020B
          ? optHeaderStart + 112
          : (magic == 0x010B ? optHeaderStart + 96 : -1);
      if (dataDirOffset < 0 || dataDirOffset + 8 > bytes.length) return false;
      final exportRva = bd.getUint32(dataDirOffset, Endian.little);
      final exportSize = bd.getUint32(dataDirOffset + 4, Endian.little);
      return exportRva > 0 && exportSize > 0;
    } catch (_) {
      return false;
    }
  }

  static String formatVigemError(int code) {
    final u = code & 0xFFFFFFFF;
    return switch (u) {
      0x20000000 => 'OK',
      0xE0000001 => 'Driver ViGEmBus belum terinstal di Windows',
      0xE0000002 => 'Semua slot controller penuh (maks 4 Xbox / DS4)',
      0xE0000003 => 'Target controller tidak valid',
      0xE0000008 => 'Versi driver ViGEmBus tidak cocok (pasang v1.22.0)',
      0xE0000009 => 'Gagal membuka akses ke driver ViGEmBus',
      _ => 'ViGEm error 0x${u.toRadixString(16).toUpperCase()}',
    };
  }

  ffi.DynamicLibrary _openVigemLibrary() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir${Platform.pathSeparator}ViGEmClient.dll',
      'ViGEmClient.dll',
    ];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add('$localAppData\\Programs\\DartPad\\ViGEmClient.dll');
    }

    Object? lastErr;
    for (final path in candidates) {
      final f = File(path);
      if (path.contains(Platform.pathSeparator)) {
        if (!f.existsSync()) continue;
        if (!isValidPeExportDll(f)) {
          lastErr = 'DLL lama/rusak tanpa export symbols: $path';
          continue;
        }
      }
      try {
        return ffi.DynamicLibrary.open(path);
      } catch (e) {
        lastErr = e;
      }
    }
    throw ArgumentError('ViGEmClient.dll tidak valid / tidak ditemukan ($lastErr)');
  }

  @override
  bool init() {
    dispose();
    _initialized = true;
    _lastState = ControllerState.neutral;

    if (!Platform.isWindows) {
      _statusMessage = 'Non-Windows simulation active';
      return true;
    }

    // 1. Bind built-in Windows user32.dll (optional keyboard fallback)
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      _keybdEventFn = user32
          .lookup<ffi.NativeFunction<_KeybdEventNative>>('keybd_event')
          .asFunction<_KeybdEventDart>();
    } catch (_) {}

    // 2. Bind ViGEmClient.dll + ViGEmBus driver
    try {
      final vigemLib = _openVigemLibrary();

      _allocFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemAllocNative>>('vigem_alloc')
          .asFunction<_VigemAllocDart>();
      _connectFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemConnectNative>>('vigem_connect')
          .asFunction<_VigemConnectDart>();
      _x360AllocFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetAllocNative>>(
            'vigem_target_x360_alloc',
          )
          .asFunction<_VigemTargetAllocDart>();
      _ds4AllocFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetAllocNative>>(
            'vigem_target_ds4_alloc',
          )
          .asFunction<_VigemTargetAllocDart>();
      _targetAddFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetAddNative>>('vigem_target_add')
          .asFunction<_VigemTargetAddDart>();
      _targetRemoveFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetRemoveNative>>(
            'vigem_target_remove',
          )
          .asFunction<_VigemTargetRemoveDart>();
      _x360UpdateFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetX360UpdateNative>>(
            'vigem_target_x360_update',
          )
          .asFunction<_VigemTargetX360UpdateDart>();
      _ds4UpdateFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemTargetDs4UpdateNative>>(
            'vigem_target_ds4_update',
          )
          .asFunction<_VigemTargetDs4UpdateDart>();
      _x360GetUserIndexFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemX360GetUserIndexNative>>(
            'vigem_target_x360_get_user_index',
          )
          .asFunction<_VigemX360GetUserIndexDart>();
      _x360GetOutputFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemX360GetOutputNative>>(
            'vigem_target_x360_get_output',
          )
          .asFunction<_VigemX360GetOutputDart>();
      _ds4GetOutputFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemDs4GetOutputNative>>(
            'vigem_target_ds4_get_output',
          )
          .asFunction<_VigemDs4GetOutputDart>();
      _vigemDisconnectFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_disconnect')
          .asFunction<_VigemFreeDart>();
      _vigemFreeFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_free')
          .asFunction<_VigemFreeDart>();
      _targetFreeFn = vigemLib
          .lookup<ffi.NativeFunction<_VigemFreeNative>>('vigem_target_free')
          .asFunction<_VigemFreeDart>();

      _hasVigemDll = true;

      final client = _allocFn!();
      if (client == ffi.nullptr) {
        _statusMessage = 'Gagal alokasi ViGEm client';
        return true;
      }

      final connRes = _connectFn!(client);
      _lastVigemError = connRes;
      if (connRes != _vigemErrorNone) {
        _vigemFreeFn!(client);
        _hasNativeVigem = false;
        _statusMessage = connRes == _vigemErrorBusNotFound
            ? 'Driver ViGEmBus belum terinstal di Windows (klik Pasang ViGEmBus agar game membaca controller)'
            : formatVigemError(connRes);
        return true;
      }

      _vigemClient = client;
      if (_attachTarget(_deviceType)) {
        _hasNativeVigem = true;
        _statusMessage = _buildActiveStatus(_deviceType);
      } else {
        _hasNativeVigem = false;
        _statusMessage =
            'Gagal memasang virtual target (${formatVigemError(_lastVigemError)})';
      }
    } catch (e) {
      _hasVigemDll = false;
      _hasNativeVigem = false;
      _statusMessage =
          'ViGEmClient.dll perlu diperbarui / dipasang — klik "Pasang ViGEmBus" ($e)';
    }

    return true;
  }

  String _buildActiveStatus(ControllerType type) {
    if (type == ControllerType.playstation) {
      return 'Virtual Sony DualShock 4 Aktif (HidGame / PS Ready)';
    }
    var slotLabel = '';
    if (_vigemClient != null &&
        _vigemTarget != null &&
        _x360GetUserIndexFn != null) {
      final idxPtr = calloc<ffi.Uint32>();
      try {
        final res = _x360GetUserIndexFn!(_vigemClient!, _vigemTarget!, idxPtr);
        if (res == _vigemErrorNone) {
          slotLabel = ' • Player #${idxPtr.value + 1}';
        }
      } catch (_) {
      } finally {
        calloc.free(idxPtr);
      }
    }
    return 'Virtual Xbox 360 Aktif$slotLabel (XInput Game Ready)';
  }

  bool _attachTarget(ControllerType type) {
    final client = _vigemClient;
    if (client == null || _targetAddFn == null) return false;

    final target = type == ControllerType.xbox
        ? _x360AllocFn?.call()
        : _ds4AllocFn?.call();
    if (target == null || target == ffi.nullptr) return false;

    final addRes = _targetAddFn!(client, target);
    _lastVigemError = addRes;
    if (addRes != _vigemErrorNone) {
      _targetFreeFn?.call(target);
      return false;
    }

    _vigemTarget = target;
    _deviceType = type;
    return true;
  }

  @override
  bool switchDeviceType(ControllerType nextType) {
    if (_deviceType == nextType && _hasNativeVigem) return true;
    _deviceType = nextType;

    if (!Platform.isWindows) {
      _statusMessage = 'Simulation (${nextType.name.toUpperCase()})';
      return true;
    }

    if (_vigemClient != null && _hasNativeVigem) {
      reset();
      if (_vigemTarget != null) {
        _targetRemoveFn?.call(_vigemClient!, _vigemTarget!);
        _targetFreeFn?.call(_vigemTarget!);
        _vigemTarget = null;
      }
      if (_attachTarget(nextType)) {
        _statusMessage = _buildActiveStatus(nextType);
        return true;
      }
      _hasNativeVigem = false;
      _statusMessage =
          'Gagal mengganti mode controller (${formatVigemError(_lastVigemError)})';
      return false;
    }
    return false;
  }

  @override
  bool update(ControllerState state) {
    if (!_initialized) return false;

    if (_hasNativeVigem && _vigemClient != null && _vigemTarget != null) {
      if (_deviceType == ControllerType.xbox && _x360UpdateFn != null) {
        final reportPtr = calloc<_XusbReport>();
        try {
          reportPtr.ref
            ..wButtons = _mapXusbButtons(state.buttonBitmask)
            ..bLeftTrigger =
                (state.leftTrigger.clamp(0.0, 1.0) * 255.0).round()
            ..bRightTrigger =
                (state.rightTrigger.clamp(0.0, 1.0) * 255.0).round()
            ..sThumbLX = (state.leftStick.x.clamp(-1.0, 1.0) * 32767.0).round()
            ..sThumbLY = (state.leftStick.y.clamp(-1.0, 1.0) * 32767.0).round()
            ..sThumbRX =
                (state.rightStick.x.clamp(-1.0, 1.0) * 32767.0).round()
            ..sThumbRY =
                (state.rightStick.y.clamp(-1.0, 1.0) * 32767.0).round();

          _x360UpdateFn!(_vigemClient!, _vigemTarget!, reportPtr.ref);
        } finally {
          calloc.free(reportPtr);
        }
      } else if (_deviceType == ControllerType.playstation &&
          _ds4UpdateFn != null) {
        final reportPtr = calloc<_Ds4Report>();
        try {
          reportPtr.ref
            ..bThumbLX =
                ((state.leftStick.x.clamp(-1.0, 1.0) + 1.0) * 127.5).round()
            ..bThumbLY =
                ((1.0 - state.leftStick.y.clamp(-1.0, 1.0)) * 127.5).round()
            ..bThumbRX =
                ((state.rightStick.x.clamp(-1.0, 1.0) + 1.0) * 127.5).round()
            ..bThumbRY =
                ((1.0 - state.rightStick.y.clamp(-1.0, 1.0)) * 127.5).round()
            ..wButtons = _mapDs4Buttons(state.buttonBitmask)
            ..bSpecial =
                (state.buttonBitmask & GamepadButton.guide.bitMask) != 0 ? 1 : 0
            ..bTriggerL = (state.leftTrigger.clamp(0.0, 1.0) * 255.0).round()
            ..bTriggerR =
                (state.rightTrigger.clamp(0.0, 1.0) * 255.0).round();

          _ds4UpdateFn!(_vigemClient!, _vigemTarget!, reportPtr.ref);
        } finally {
          calloc.free(reportPtr);
        }
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
    if (!_initialized) return false;
    return update(ControllerState.neutral);
  }

  @override
  void dispose() {
    if (_vigemClient != null) {
      if (_hasNativeVigem) {
        try {
          reset();
        } catch (_) {}
      }
      if (_vigemTarget != null) {
        try {
          _targetRemoveFn?.call(_vigemClient!, _vigemTarget!);
        } catch (_) {}
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
    if ((mask & (1 << 15)) != 0) wButtons |= 0x0040; // L3
    if ((mask & (1 << 16)) != 0) wButtons |= 0x0080; // R3
    return wButtons;
  }

  static int _mapDs4Buttons(int mask) {
    final up = (mask & (1 << 8)) != 0;
    final down = (mask & (1 << 9)) != 0;
    final left = (mask & (1 << 10)) != 0;
    final right = (mask & (1 << 11)) != 0;

    int dpad = 0x8; // DS4_BUTTON_DPAD_NONE
    if (up && right) {
      dpad = 0x1;
    } else if (up && left) {
      dpad = 0x7;
    } else if (down && right) {
      dpad = 0x3;
    } else if (down && left) {
      dpad = 0x5;
    } else if (up) {
      dpad = 0x0;
    } else if (right) {
      dpad = 0x2;
    } else if (down) {
      dpad = 0x4;
    } else if (left) {
      dpad = 0x6;
    }

    var wButtons = dpad & 0xF;
    if ((mask & (1 << 2)) != 0) wButtons |= 1 << 4; // Square (west)
    if ((mask & (1 << 0)) != 0) wButtons |= 1 << 5; // Cross (south)
    if ((mask & (1 << 1)) != 0) wButtons |= 1 << 6; // Circle (east)
    if ((mask & (1 << 3)) != 0) wButtons |= 1 << 7; // Triangle (north)
    if ((mask & (1 << 4)) != 0) wButtons |= 1 << 8; // L1
    if ((mask & (1 << 5)) != 0) wButtons |= 1 << 9; // R1
    if ((mask & (1 << 6)) != 0) wButtons |= 1 << 10; // L2 digital
    if ((mask & (1 << 7)) != 0) wButtons |= 1 << 11; // R2 digital
    if ((mask & (1 << 13)) != 0) wButtons |= 1 << 12; // Share (select)
    if ((mask & (1 << 12)) != 0) wButtons |= 1 << 13; // Options (start)
    if ((mask & (1 << 15)) != 0) wButtons |= 1 << 14; // L3
    if ((mask & (1 << 16)) != 0) wButtons |= 1 << 15; // R3
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
        _keybdEventFn!(entry.value, 0, isNowPressed ? 0 : 2, 0);
      }
    }
  }
}
