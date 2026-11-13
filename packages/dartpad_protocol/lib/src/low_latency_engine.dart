import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'controller_state.dart';
import 'gamepad_button.dart';
import 'packet_codec.dart';
import 'pairing_payload.dart';

/// Ultra-low-latency sender engine for DartPad.
///
/// Key latency optimizations:
/// 1. **Instant Edge-Triggered Dispatch (`sendImmediate: true`)**:
///    Whenever a button/trigger/combo is pressed or released, a packet is sent
///    immediately on the same microtask without waiting for the next periodic tick
///    (saves up to 8.3ms–16.6ms of input lag).
/// 2. **Zero-Allocation Buffer Reuse**:
///    Reuses a single 28-byte `Uint8List` + `ByteData` view for all `INPUT` packets
///    to avoid Dart GC pauses during gameplay.
/// 3. **High-Frequency State Sync (default 120 Hz)**:
///    Continuously streams full controller state so dropped UDP packets self-heal
///    within ~8.3ms.
class LowLatencyInputSender {
  final RawDatagramSocket socket;
  final InternetAddress targetAddress;
  final int targetPort;
  final int sessionFlag;
  final int updateRateHz;

  final Uint8List _reusableBuffer =
      Uint8List(DartPadProtocolConstants.inputPacketSize);
  late final ByteData _reusableByteData =
      ByteData.sublistView(_reusableBuffer);

  ControllerState _currentState = ControllerState.neutral;
  int _sequence = 0;
  int _packetsSent = 0;
  Timer? _periodicTimer;
  final Stopwatch _clock = Stopwatch()..start();

  LowLatencyInputSender({
    required this.socket,
    required this.targetAddress,
    this.targetPort = DartPadProtocolConstants.defaultPort,
    required String sessionToken,
    this.updateRateHz = 120,
  }) : sessionFlag = PairingPayload.computeSessionFlag(sessionToken);

  ControllerState get currentState => _currentState;
  int get sequence => _sequence;
  int get packetsSent => _packetsSent;

  /// Starts the high-frequency periodic state synchronization loop (default 120 Hz).
  void startLoop() {
    stopLoop();
    final intervalMicros = (1000000 / updateRateHz).round();
    _periodicTimer = Timer.periodic(
      Duration(microseconds: intervalMicros),
      (_) => _flushCurrentState(),
    );
  }

  /// Stops the periodic loop.
  void stopLoop() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Updates the controller state.
  /// If [immediate] is true (default when buttons change), dispatches the UDP packet
  /// immediately (`0 ms` timer wait) before the next periodic tick.
  void updateState(ControllerState newState, {bool immediate = true}) {
    final buttonsChanged = newState.buttonBitmask != _currentState.buttonBitmask ||
        newState.leftTrigger != _currentState.leftTrigger ||
        newState.rightTrigger != _currentState.rightTrigger;
    _currentState = newState;

    if (immediate || buttonsChanged) {
      _flushCurrentState();
    }
  }

  /// Immediately presses or releases a single [GamepadButton] or trigger and flushes to UDP.
  void setButtonPressed(GamepadButton button, bool isPressed) {
    final nextButtons = Set<GamepadButton>.from(_currentState.buttons);
    if (isPressed) {
      nextButtons.add(button);
    } else {
      nextButtons.remove(button);
    }

    var lt = _currentState.leftTrigger;
    var rt = _currentState.rightTrigger;
    if (button == GamepadButton.leftTrigger) {
      lt = isPressed ? 1.0 : 0.0;
    } else if (button == GamepadButton.rightTrigger) {
      rt = isPressed ? 1.0 : 0.0;
    }

    updateState(
      _currentState.copyWith(
        buttons: nextButtons,
        leftTrigger: lt,
        rightTrigger: rt,
      ),
      immediate: true,
    );
  }

  void _flushCurrentState() {
    _sequence = (_sequence + 1) & 0xFFFFFFFF;
    final packet = InputPacket(
      sequence: _sequence,
      timestampMs: _clock.elapsedMilliseconds,
      state: _currentState,
      flags: sessionFlag,
    );

    PacketCodec.encodeInputInto(packet, _reusableByteData);
    socket.send(_reusableBuffer, targetAddress, targetPort);
    _packetsSent++;
  }
}

/// Tracks incoming UDP sequence numbers on the Receiver to drop out-of-order
/// packets and measure real-time packet loss & jitter.
class SequenceTracker {
  int? _lastSequence;
  int _acceptedPackets = 0;
  int _droppedOutOfOrder = 0;
  int _missedSequenceGaps = 0;

  int get acceptedPackets => _acceptedPackets;
  int get droppedOutOfOrder => _droppedOutOfOrder;
  int get missedSequenceGaps => _missedSequenceGaps;

  /// Packet loss ratio (`0.0` .. `1.0`).
  double get packetLossRatio {
    final totalExpected = _acceptedPackets + _missedSequenceGaps;
    if (totalExpected <= 0) return 0.0;
    return _missedSequenceGaps / totalExpected;
  }

  /// Returns `true` if [sequence] is newer than the last accepted packet.
  /// Returns `false` if [sequence] is older/duplicate (out-of-order UDP arrival),
  /// preventing stale input states from overwriting newer button presses.
  bool accept(int sequence) {
    if (_lastSequence == null) {
      _lastSequence = sequence;
      _acceptedPackets++;
      return true;
    }

    // Handle 32-bit wrap-around safely
    final diff = (sequence - _lastSequence!) & 0xFFFFFFFF;
    if (diff == 0 || diff > 0x80000000) {
      // Duplicate or older packet arrived out of order -> drop!
      _droppedOutOfOrder++;
      return false;
    }

    if (diff > 1) {
      _missedSequenceGaps += (diff - 1);
    }

    _lastSequence = sequence;
    _acceptedPackets++;
    return true;
  }

  void reset() {
    _lastSequence = null;
    _acceptedPackets = 0;
    _droppedOutOfOrder = 0;
    _missedSequenceGaps = 0;
  }
}
