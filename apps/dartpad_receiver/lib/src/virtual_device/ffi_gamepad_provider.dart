import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:ffi/ffi.dart';

import 'gamepad_provider.dart';

// Native C signatures matching `native/dartpad_vgamepad/dartpad_vgamepad.h`
typedef _InitNative = ffi.Int32 Function(ffi.Int32 deviceType);
typedef _InitDart = int Function(int deviceType);

typedef _UpdateNative = ffi.Int32 Function(
  ffi.Uint32 buttonsBitmask,
  ffi.Int16 lx,
  ffi.Int16 ly,
  ffi.Int16 rx,
  ffi.Int16 ry,
  ffi.Uint8 lt,
  ffi.Uint8 rt,
);
typedef _UpdateDart = int Function(
  int buttonsBitmask,
  int lx,
  int ly,
  int rx,
  int ry,
  int lt,
  int rt,
);

typedef _ResetNative = ffi.Int32 Function();
typedef _ResetDart = int Function();

typedef _PollRumbleNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> outLargeMotor,
  ffi.Pointer<ffi.Uint8> outSmallMotor,
);
typedef _PollRumbleDart = int Function(
  ffi.Pointer<ffi.Uint8> outLargeMotor,
  ffi.Pointer<ffi.Uint8> outSmallMotor,
);

typedef _DestroyNative = ffi.Void Function();
typedef _DestroyDart = void Function();

/// Native FFI implementation of [GamepadProvider] that bridges Dart to
/// `dartpad_vgamepad.dll` (Windows) or `libdartpad_vgamepad.so` (Linux test).
class FfiGamepadProvider implements GamepadProvider {
  @override
  final ControllerType deviceType;

  final String? libraryPath;
  final void Function(ControllerState state)? onStateUpdated;

  ffi.DynamicLibrary? _lib;
  _InitDart? _initFn;
  _UpdateDart? _updateFn;
  _ResetDart? _resetFn;
  _PollRumbleDart? _pollRumbleFn;
  _DestroyDart? _destroyFn;

  ffi.Pointer<ffi.Uint8>? _largeMotorPtr;
  ffi.Pointer<ffi.Uint8>? _smallMotorPtr;

  bool _initialized = false;
  ControllerState _lastState = ControllerState.neutral;

  FfiGamepadProvider({
    this.deviceType = ControllerType.xbox,
    this.libraryPath,
    this.onStateUpdated,
  });

  @override
  bool get isInitialized => _initialized;

  @override
  bool get isHardwareDriverActive => _initialized;

  @override
  String get driverStatusSummary =>
      _initialized ? 'Native FFI (${deviceType.name.toUpperCase()})' : 'Inactive';

  @override
  bool switchDeviceType(ControllerType nextType) => nextType == deviceType;

  ControllerState get lastState => _lastState;

  static String defaultLibraryName() {
    if (Platform.isWindows) return 'dartpad_vgamepad.dll';
    if (Platform.isMacOS) return 'libdartpad_vgamepad.dylib';
    return 'libdartpad_vgamepad.so';
  }

  @override
  bool init() {
    try {
      final path = libraryPath ?? defaultLibraryName();
      _lib = ffi.DynamicLibrary.open(path);

      _initFn = _lib!
          .lookup<ffi.NativeFunction<_InitNative>>('dartpad_vgamepad_init')
          .asFunction<_InitDart>();
      _updateFn = _lib!
          .lookup<ffi.NativeFunction<_UpdateNative>>('dartpad_vgamepad_update')
          .asFunction<_UpdateDart>();
      _resetFn = _lib!
          .lookup<ffi.NativeFunction<_ResetNative>>('dartpad_vgamepad_reset')
          .asFunction<_ResetDart>();
      _pollRumbleFn = _lib!
          .lookup<ffi.NativeFunction<_PollRumbleNative>>(
            'dartpad_vgamepad_poll_rumble',
          )
          .asFunction<_PollRumbleDart>();
      _destroyFn = _lib!
          .lookup<ffi.NativeFunction<_DestroyNative>>('dartpad_vgamepad_destroy')
          .asFunction<_DestroyDart>();

      _largeMotorPtr = calloc<ffi.Uint8>();
      _smallMotorPtr = calloc<ffi.Uint8>();

      final nativeType = deviceType == ControllerType.playstation ? 1 : 0;
      final res = _initFn!(nativeType);
      _initialized = (res == 0);
      return _initialized;
    } catch (_) {
      _initialized = false;
      return false;
    }
  }

  @override
  RumbleEvent? pollRumble() {
    if (!_initialized ||
        _pollRumbleFn == null ||
        _largeMotorPtr == null ||
        _smallMotorPtr == null) {
      return null;
    }
    final hasNew = _pollRumbleFn!(_largeMotorPtr!, _smallMotorPtr!);
    if (hasNew == 1) {
      return RumbleEvent.fromRawMotors(
        largeMotorByte: _largeMotorPtr!.value,
        smallMotorByte: _smallMotorPtr!.value,
      );
    }
    return null;
  }

  @override
  bool update(ControllerState state) {
    if (!_initialized || _updateFn == null) return false;
    final lx = (state.leftStick.x.clamp(-1.0, 1.0) * 32767.0).round();
    final ly = (state.leftStick.y.clamp(-1.0, 1.0) * 32767.0).round();
    final rx = (state.rightStick.x.clamp(-1.0, 1.0) * 32767.0).round();
    final ry = (state.rightStick.y.clamp(-1.0, 1.0) * 32767.0).round();
    final lt = (state.leftTrigger.clamp(0.0, 1.0) * 255.0).round();
    final rt = (state.rightTrigger.clamp(0.0, 1.0) * 255.0).round();

    final res = _updateFn!(
      state.buttonBitmask,
      lx,
      ly,
      rx,
      ry,
      lt,
      rt,
    );
    if (res == 0) {
      _lastState = state;
      onStateUpdated?.call(state);
      return true;
    }
    return false;
  }

  @override
  bool reset() {
    if (!_initialized || _resetFn == null) return false;
    final res = _resetFn!();
    if (res == 0) {
      _lastState = ControllerState.neutral;
      onStateUpdated?.call(_lastState);
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    if (_initialized && _destroyFn != null) {
      _destroyFn!();
    }
    if (_largeMotorPtr != null) {
      calloc.free(_largeMotorPtr!);
      _largeMotorPtr = null;
    }
    if (_smallMotorPtr != null) {
      calloc.free(_smallMotorPtr!);
      _smallMotorPtr = null;
    }
    _initialized = false;
  }
}
