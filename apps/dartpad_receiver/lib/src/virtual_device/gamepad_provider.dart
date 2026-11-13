import 'package:dartpad_protocol/dartpad_protocol.dart';

/// Abstract interface for virtual gamepad device backends on Windows
/// (e.g., ViGEmBus, Virtual HID Framework / VHF, or In-Memory Test Provider).
abstract class GamepadProvider {
  ControllerType get deviceType;
  bool get isInitialized;

  /// Initializes the virtual controller device with the OS driver.
  bool init();

  /// Pushes the latest [ControllerState] to the virtual gamepad device immediately.
  bool update(ControllerState state);

  /// Resets all buttons, sticks, and triggers to neutral (`0`) immediately.
  bool reset();

  /// Polls the virtual gamepad driver for a new Force Feedback / [RumbleEvent]
  /// requested by the PC game. Returns `null` if no new rumble occurred.
  RumbleEvent? pollRumble() => null;

  /// Unplugs the virtual controller and frees native resources.
  void dispose();
}

/// In-memory / simulation [GamepadProvider] that records every button & axis
/// update and notifies listeners. Used for:
/// 1. Real-time button response verification in the Windows EXE (`Controller Test`).
/// 2. Automated E2E tests or running the receiver when the Windows kernel driver
///    is not yet installed.
class SimulatedGamepadProvider implements GamepadProvider {
  @override
  final ControllerType deviceType;

  bool _initialized = false;
  ControllerState _lastState = ControllerState.neutral;
  int _updateCount = 0;
  int _resetCount = 0;
  RumbleEvent? _pendingRumble;
  final void Function(ControllerState state)? onStateChanged;

  SimulatedGamepadProvider({
    this.deviceType = ControllerType.xbox,
    this.onStateChanged,
  });

  @override
  bool get isInitialized => _initialized;

  ControllerState get lastState => _lastState;
  int get updateCount => _updateCount;
  int get resetCount => _resetCount;

  /// Queues a simulated [RumbleEvent] as if a PC game triggered force feedback.
  void triggerSimulatedRumble(RumbleEvent rumble) {
    _pendingRumble = rumble;
  }

  @override
  RumbleEvent? pollRumble() {
    final evt = _pendingRumble;
    _pendingRumble = null;
    return evt;
  }

  @override
  bool init() {
    _initialized = true;
    _lastState = ControllerState.neutral;
    return true;
  }

  @override
  bool update(ControllerState state) {
    if (!_initialized) return false;
    _lastState = state;
    _updateCount++;
    onStateChanged?.call(state);
    return true;
  }

  @override
  bool reset() {
    if (!_initialized) return false;
    _lastState = ControllerState.neutral;
    _resetCount++;
    onStateChanged?.call(_lastState);
    return true;
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
