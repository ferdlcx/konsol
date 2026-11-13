import 'dart:async';
import 'dart:io';

import 'controller_layout.dart';
import 'controller_profile.dart';
import 'controller_state.dart';
import 'gamepad_button.dart';
import 'low_latency_engine.dart';
import 'packet_codec.dart';
import 'pairing_payload.dart';
import 'rumble_feedback.dart';

/// Client-side Input Engine & Network Session Manager running on the Android
/// device (`dartpad_mobile`).
///
/// Responsibilities:
/// - Connects to the Windows PC Receiver via scanned QR Code (`PairingPayload`)
///   or manual IP + 6-digit PIN.
/// - Aggregates multi-touch button presses, custom Combo buttons, 360° analog
///   sticks (with radial deadzone & sensitivity), and physical Volume Up/Down
///   hardware keys (`LT`/`RT`).
/// - Immediately dispatches edge-triggered 28-byte UDP packets (`0 ms` timer wait)
///   plus a continuous 120 Hz synchronization loop via [LowLatencyInputSender].
/// - Receives real-time `RUMBLE` force-feedback packets from the Windows PC Game
///   and triggers [onRumbleReceived] to vibrate the Android phone.
/// - Measures round-trip latency (RTT ms) via periodic `HEARTBEAT` echoes.
class MobileControllerEngine {
  ControllerProfile _profile;
  ControllerLayout _layout;
  final int updateRateHz;
  final void Function(ControllerState state)? onStateChanged;
  final void Function(bool connected, double rttMs)? onConnectionChanged;
  final void Function(RumbleEvent rumble)? onRumbleReceived;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  LowLatencyInputSender? _sender;
  Timer? _heartbeatTimer;

  ControllerState _currentState = ControllerState.neutral;
  final Map<String, Set<GamepadButton>> _activeTouchSources = {};
  final Set<HardwareKey> _pressedHardwareKeys = {};

  bool _isConnected = false;
  String? _sessionToken;
  String? _connectedServerName;
  double _lastRttMs = 0.0;
  int _heartbeatSeq = 0;
  RumbleEvent? _lastRumble;
  final Stopwatch _rttClock = Stopwatch()..start();

  MobileControllerEngine({
    ControllerProfile? profile,
    ControllerLayout? layout,
    this.updateRateHz = 120,
    this.onStateChanged,
    this.onConnectionChanged,
    this.onRumbleReceived,
  })  : _profile = profile ?? ControllerProfile.xboxDefault(),
        _layout = layout ?? ControllerLayout.defaultLandscape();

  ControllerProfile get profile => _profile;
  ControllerLayout get layout => _layout;
  ControllerState get currentState => _currentState;
  bool get isConnected => _isConnected;
  String? get connectedServerName => _connectedServerName;
  double get lastRttMs => _lastRttMs;
  int get packetsSent => _sender?.packetsSent ?? 0;
  RumbleEvent? get lastRumble => _lastRumble;

  /// Switches the active controller profile (e.g., Xbox <-> PlayStation or custom deadzone/volume trigger config).
  void setProfile(ControllerProfile nextProfile) {
    _profile = nextProfile;
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Updates the active customizable layout (button positions, scales, combo buttons).
  void setLayout(ControllerLayout nextLayout) {
    _layout = nextLayout;
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Connects and pairs with the Windows Receiver using a scanned QR Code URI string
  /// (`dartpad://connect?ip=...&port=...&pin=...&name=...`).
  Future<bool> connectFromQrUri(
    String qrUriString, {
    String clientDeviceName = 'DartPad Android',
    Duration timeout = const Duration(seconds: 3),
  }) {
    final payload = PairingPayload.fromQrUriString(qrUriString);
    return connectWithPayload(
      payload,
      clientDeviceName: clientDeviceName,
      timeout: timeout,
    );
  }

  /// Connects and pairs with the Windows Receiver using a [PairingPayload].
  Future<bool> connectWithPayload(
    PairingPayload payload, {
    String clientDeviceName = 'DartPad Android',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await disconnect();

    final targetAddr = InternetAddress.tryParse(payload.ip);
    if (targetAddr == null) {
      throw FormatException('Invalid receiver IP address: ${payload.ip}');
    }

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket = socket;

    final handshakeCompleter = Completer<bool>();

    _socketSub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        final type = PacketCodec.peekPacketType(dg!.data);
        if (type == null || type == PacketType.input) continue;

        try {
          final ctrl = PacketCodec.decodeControl(dg.data);
          if (ctrl.type == PacketType.accept) {
            _sessionToken = ctrl.payload['sessionToken'] as String?;
            _connectedServerName =
                ctrl.payload['serverName'] as String? ?? payload.deviceName;
            if (_sessionToken != null && !handshakeCompleter.isCompleted) {
              handshakeCompleter.complete(true);
            }
          } else if (ctrl.type == PacketType.reject) {
            if (!handshakeCompleter.isCompleted) {
              handshakeCompleter.complete(false);
            }
          } else if (ctrl.type == PacketType.heartbeatAck) {
            final nowMs = _rttClock.elapsedMilliseconds & 0xFFFFFFFF;
            final diff = (nowMs - ctrl.timestampMs) & 0xFFFFFFFF;
            if (diff < 10000) {
              _lastRttMs = diff.toDouble();
              onConnectionChanged?.call(_isConnected, _lastRttMs);
            }
          } else if (ctrl.type == PacketType.rumble) {
            final rumble = RumbleEvent.fromControlPacket(ctrl);
            _lastRumble = rumble;
            onRumbleReceived?.call(rumble);
          }
        } on FormatException {
          // Ignore malformed packets
        }
      }
    });

    final connectPacket = PacketCodec.encodeControl(
      ControlPacket(
        type: PacketType.connect,
        sequence: 1,
        timestampMs: _rttClock.elapsedMilliseconds,
        payload: {
          'pin': payload.pin,
          'deviceName': clientDeviceName,
        },
      ),
    );
    socket.send(connectPacket, targetAddr, payload.port);

    final accepted = await handshakeCompleter.future.timeout(
      timeout,
      onTimeout: () => false,
    );

    if (!accepted || _sessionToken == null) {
      await disconnect();
      return false;
    }

    _isConnected = true;
    _sender = LowLatencyInputSender(
      socket: socket,
      targetAddress: targetAddr,
      targetPort: payload.port,
      sessionToken: _sessionToken!,
      updateRateHz: updateRateHz,
    )..startLoop();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _heartbeatSeq++;
      final hb = PacketCodec.encodeControl(
        ControlPacket(
          type: PacketType.heartbeat,
          sequence: _heartbeatSeq,
          timestampMs: _rttClock.elapsedMilliseconds,
        ),
      );
      _socket?.send(hb, targetAddr, payload.port);
    });

    onConnectionChanged?.call(true, _lastRttMs);
    return true;
  }

  /// Handles touch down/up on any layout item (Single Button or Multi-Button Combo).
  /// Safe for multi-touch: releasing one finger will not release a shared button
  /// if another finger/combo is still holding it down.
  void handleLayoutItemTouch(String itemId, bool isPressed) {
    final item = _layout.items.where((e) => e.id == itemId).firstOrNull;
    if (item == null || !item.visible || item.actions.isEmpty) return;

    if (isPressed) {
      _activeTouchSources[itemId] = item.actions.toSet();
    } else {
      _activeTouchSources.remove(itemId);
    }

    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Directly presses/releases a specific [GamepadButton] (e.g. from D-Pad directional zones).
  void handleDirectButton(String sourceKey, GamepadButton button, bool isPressed) {
    if (isPressed) {
      _activeTouchSources[sourceKey] = {button};
    } else {
      _activeTouchSources.remove(sourceKey);
    }
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Intercepts physical Android Volume Up / Volume Down keys and translates them
  /// into virtual triggers (`LT`/`RT` or custom binding) with `0 ms` dispatch delay.
  /// Returns `true` if the key event was consumed so Android does not show the volume popup.
  bool handleHardwareKeyEvent(HardwareKey key, bool isPressed) {
    if (!_profile.enableVolumeKeysAsTriggers) return false;
    if (!_profile.hardwareKeyBindings.containsKey(key)) return false;

    if (isPressed) {
      _pressedHardwareKeys.add(key);
    } else {
      _pressedHardwareKeys.remove(key);
    }

    _recomputeButtonsAndFlush(immediate: true);
    return true;
  }

  /// Updates the Left or Right 360° analog stick from raw touch offset (`-1.0 .. 1.0`),
  /// automatically applying the profile's radial deadzone, sensitivity, and circular clamping.
  void handleJoystickMove({
    required bool isLeftStick,
    required double rawX,
    required double rawY,
  }) {
    final normalized = StickState(x: rawX, y: rawY).normalize(
      deadzone: _profile.deadzone,
      sensitivity: _profile.sensitivity,
      clampCircular: true,
    );

    _currentState = isLeftStick
        ? _currentState.copyWith(leftStick: normalized)
        : _currentState.copyWith(rightStick: normalized);

    _sender?.updateState(_currentState, immediate: true);
    onStateChanged?.call(_currentState);
  }

  /// Releases all pressed buttons, triggers, and sticks immediately (e.g., when app is backgrounded).
  void releaseAllInputs() {
    _activeTouchSources.clear();
    _pressedHardwareKeys.clear();
    _currentState = ControllerState.neutral;
    _sender?.updateState(_currentState, immediate: true);
    onStateChanged?.call(_currentState);
  }

  /// Cleanly disconnects from the PC Receiver and releases all inputs first.
  Future<void> disconnect() async {
    releaseAllInputs();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _sender?.stopLoop();
    _sender = null;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _isConnected = false;
    _sessionToken = null;
    onConnectionChanged?.call(false, 0.0);
  }

  void _recomputeButtonsAndFlush({required bool immediate}) {
    final mergedButtons = <GamepadButton>{};

    // 1. Merge all active touch buttons & combo buttons
    for (final actions in _activeTouchSources.values) {
      mergedButtons.addAll(actions);
    }

    // 2. Merge physical hardware keys (Volume Up / Volume Down)
    if (_profile.enableVolumeKeysAsTriggers) {
      for (final hwKey in _pressedHardwareKeys) {
        final target = _profile.hardwareKeyBindings[hwKey];
        if (target != null) {
          mergedButtons.add(target);
        }
      }
    }

    final lt = mergedButtons.contains(GamepadButton.leftTrigger) ? 1.0 : 0.0;
    final rt = mergedButtons.contains(GamepadButton.rightTrigger) ? 1.0 : 0.0;

    _currentState = _currentState.copyWith(
      buttons: mergedButtons,
      leftTrigger: lt,
      rightTrigger: rt,
    );

    _sender?.updateState(_currentState, immediate: immediate);
    onStateChanged?.call(_currentState);
  }
}
