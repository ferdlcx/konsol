import 'dart:async';
import 'dart:io';

import 'config_store.dart';
import 'controller_layout.dart';
import 'controller_profile.dart';
import 'controller_state.dart';
import 'gamepad_button.dart';
import 'low_latency_engine.dart';
import 'packet_codec.dart';
import 'pairing_payload.dart';
import 'rumble_feedback.dart';

/// Client-side Input Engine, Macro Sequence Runner, & Automatic Wi-Fi / USB
/// Pairing Manager running on the Android device (`dartpad_mobile`).
///
/// Key capabilities:
/// 1. **Automatic Wi-Fi & USB Tethering Discovery + Auto-Pairing**:
///    Scans saved PC host, LAN broadcast (`255.255.255.255`), active subnet
///    broadcasts, and USB Tethering / RNDIS / Hotspot gateways (`192.168.42.x`,
///    `192.168.137.1`, `192.168.43.1`, `127.0.0.1`) so the phone connects
///    without requiring manual IP/PIN entry.
/// 2. **Persistent Storage Across Reboots**:
///    Automatically saves and restores paired PC credentials, custom layouts,
///    combos, themes, and settings via [DartPadConfigStore].
/// 3. **Instant & Sequential Millisecond Combo Macros**:
///    Executes both simultaneous combos (`LB + RB`) and sequential macros
///    (`(1)` `X -> Y -> A -> A` with configurable millisecond intervals).
class MobileControllerEngine {
  ControllerProfile _profile;
  ControllerLayout _layout;
  DartPadAppSettings _settings;
  final DartPadConfigStore? configStore;
  final int updateRateHz;
  final void Function(ControllerState state)? onStateChanged;
  final void Function(bool connected, double rttMs)? onConnectionChanged;
  final void Function(RumbleEvent rumble)? onRumbleReceived;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  LowLatencyInputSender? _sender;
  Timer? _heartbeatTimer;
  Timer? _autoConnectTimer;
  bool _isAttemptingAutoConnect = false;

  ControllerState _currentState = ControllerState.neutral;
  final Map<String, Set<GamepadButton>> _activeTouchSources = {};
  final Set<HardwareKey> _pressedHardwareKeys = {};
  int _macroRunId = 0;

  bool _isConnected = false;
  String? _sessionToken;
  String? _connectedServerName;
  String? _connectedServerIp;
  double _lastRttMs = 0.0;
  int _heartbeatSeq = 0;
  int _lastAckTimeMs = 0;
  RumbleEvent? _lastRumble;
  final Stopwatch _rttClock = Stopwatch()..start();

  MobileControllerEngine({
    ControllerProfile? profile,
    ControllerLayout? layout,
    DartPadAppSettings? settings,
    this.configStore,
    this.updateRateHz = 120,
    this.onStateChanged,
    this.onConnectionChanged,
    this.onRumbleReceived,
  })  : _profile = profile ?? ControllerProfile.xboxDefault(),
        _layout = layout ?? ControllerLayout.defaultLandscape(),
        _settings = settings ?? const DartPadAppSettings();

  ControllerProfile get profile => _profile;
  ControllerLayout get layout => _layout;
  DartPadAppSettings get settings => _settings;
  ControllerState get currentState => _currentState;
  bool get isConnected => _isConnected;
  String? get connectedServerName => _connectedServerName;
  String? get connectedServerIp => _connectedServerIp;
  double get lastRttMs => _lastRttMs;
  int get packetsSent => _sender?.packetsSent ?? 0;
  RumbleEvent? get lastRumble => _lastRumble;

  /// Loads saved profile, layout, settings, and last paired PC from persistent
  /// disk storage, and starts the background Auto-Pair / Auto-Reconnect loop.
  Future<void> initializeFromDisk({bool startBackgroundAutoPair = true}) async {
    final store = configStore;
    if (store != null) {
      await store.ensureInitialized();
      _settings = await store.loadSettings();
      _profile = await store.loadProfile(_settings.activeProfileId);
      _layout = await store.loadLayout(_settings.activeLayoutId);
      onStateChanged?.call(_currentState);
    }

    if (startBackgroundAutoPair && _settings.autoPairEnabled) {
      startAutoConnectLoop();
    }
  }

  /// Updates app settings (theme, global scale, auto-pair) and persists to disk.
  Future<void> updateSettings(DartPadAppSettings nextSettings) async {
    _settings = nextSettings;
    await configStore?.saveSettings(nextSettings);
    if (_settings.autoPairEnabled && _autoConnectTimer == null) {
      startAutoConnectLoop();
    } else if (!_settings.autoPairEnabled) {
      stopAutoConnectLoop();
    }
  }

  /// Switches the active controller profile and persists it to disk immediately.
  void setProfile(ControllerProfile nextProfile) {
    _profile = nextProfile;
    _settings = _settings.copyWith(activeProfileId: nextProfile.id);
    configStore?.saveProfile(nextProfile);
    configStore?.saveSettings(_settings);
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Updates the active customizable layout (button positions, scales, combos)
  /// and persists it to disk immediately so it survives device shutdown.
  void setLayout(ControllerLayout nextLayout) {
    _layout = nextLayout;
    _settings = _settings.copyWith(activeLayoutId: nextLayout.id);
    configStore?.saveLayout(nextLayout);
    configStore?.saveSettings(_settings);
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Starts a non-blocking background loop that automatically discovers & pairs
  /// with any Windows PC running `DartPad.exe` over Wi-Fi or USB Tethering.
  void startAutoConnectLoop({
    Duration interval = const Duration(seconds: 3),
  }) {
    stopAutoConnectLoop();
    // Trigger first scan immediately
    unawaited(_tryAutoConnectTick());
    _autoConnectTimer = Timer.periodic(interval, (_) {
      unawaited(_tryAutoConnectTick());
    });
  }

  void stopAutoConnectLoop() {
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
  }

  Future<void> _tryAutoConnectTick() async {
    if (_isConnected || _isAttemptingAutoConnect || !_settings.autoPairEnabled) {
      return;
    }
    _isAttemptingAutoConnect = true;
    try {
      await discoverAndAutoConnect(
        port: _settings.lastConnectedPort,
        timeout: const Duration(milliseconds: 900),
      );
    } catch (_) {
    } finally {
      _isAttemptingAutoConnect = false;
    }
  }

  /// Automatically discovers a running `DartPad.exe` PC Receiver over Wi-Fi LAN
  /// OR USB Tethering (RNDIS / Hotspot / ADB) and pairs without manual typing!
  Future<bool> discoverAndAutoConnect({
    int port = DartPadProtocolConstants.defaultPort,
    Duration timeout = const Duration(milliseconds: 1200),
    String clientDeviceName = 'DartPad Android',
  }) async {
    // 1. If we have a previously saved PC IP & PIN from before device shutdown,
    //    try fast direct reconnect first!
    if (_settings.lastConnectedIp != null &&
        _settings.lastPairedPin != null &&
        _settings.lastConnectedIp!.isNotEmpty &&
        _settings.lastPairedPin!.isNotEmpty) {
      final reconnected = await connectWithPayload(
        PairingPayload(
          ip: _settings.lastConnectedIp!,
          port: _settings.lastConnectedPort,
          pin: _settings.lastPairedPin!,
          deviceName: _settings.lastPairedServerName ?? 'Windows PC',
        ),
        clientDeviceName: clientDeviceName,
        timeout: const Duration(milliseconds: 450),
      );
      if (reconnected) return true;
    }

    // 2. Fast probe for local / USB / saved host first, then full Wi-Fi & USB subnet broadcast
    final fastTargets = <String>[
      if (_settings.lastConnectedIp != null &&
          _settings.lastConnectedIp!.isNotEmpty)
        _settings.lastConnectedIp!,
      '127.0.0.1',
    ];

    var discovered = await _probeTargetsForReceiver(
      targets: fastTargets,
      port: port,
      timeout: const Duration(milliseconds: 180),
    );

    if (discovered == null) {
      final allTargets = await _collectDiscoveryTargets(
        savedIp: _settings.lastConnectedIp,
      );
      discovered = await _probeTargetsForReceiver(
        targets: allTargets,
        port: port,
        timeout: timeout,
      );
    }

    if (discovered == null) return false;

    return await connectWithPayload(
      discovered,
      clientDeviceName: clientDeviceName,
      timeout: const Duration(seconds: 2),
    );
  }

  Future<PairingPayload?> _probeTargetsForReceiver({
    required Iterable<String> targets,
    required int port,
    required Duration timeout,
  }) async {
    final sockets = <RawDatagramSocket>[];
    final subs = <StreamSubscription<RawSocketEvent>>[];
    final foundCompleter = Completer<PairingPayload?>();

    final discoverBytes = PacketCodec.encodeControl(
      ControlPacket(
        type: PacketType.discover,
        sequence: 1,
        timestampMs: _rttClock.elapsedMilliseconds,
      ),
    );

    try {
      for (final ip in targets) {
        final addr = InternetAddress.tryParse(ip);
        if (addr == null) continue;
        try {
          final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
          if (ip.endsWith('.255')) {
            try {
              sock.broadcastEnabled = true;
            } catch (_) {}
          }
          sockets.add(sock);

          final sub = sock.listen(
            (event) {
              if (event != RawSocketEvent.read) return;
              Datagram? dg;
              while ((dg = sock.receive()) != null) {
                final type = PacketCodec.peekPacketType(dg!.data);
                if (type != PacketType.discoverResponse) continue;
                try {
                  final ctrl = PacketCodec.decodeControl(dg.data);
                  final pin = ctrl.payload['pin']?.toString() ?? '';
                  final srvName =
                      ctrl.payload['serverName']?.toString() ?? 'Windows PC';
                  final srvPort =
                      (ctrl.payload['port'] as num?)?.toInt() ?? dg.port;
                  if (pin.isNotEmpty && !foundCompleter.isCompleted) {
                    foundCompleter.complete(
                      PairingPayload(
                        ip: dg.address.address,
                        port: srvPort,
                        pin: pin,
                        deviceName: srvName,
                      ),
                    );
                  }
                } catch (_) {}
              }
            },
            onError: (_) {},
          );
          subs.add(sub);
          sock.send(discoverBytes, addr, port);
        } catch (_) {}
      }

      return await foundCompleter.future.timeout(
        timeout,
        onTimeout: () => null,
      );
    } finally {
      for (final sub in subs) {
        await sub.cancel();
      }
      for (final sock in sockets) {
        sock.close();
      }
    }
  }

  /// Connects and pairs with the Windows Receiver using a scanned QR Code URI string.
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

  /// Connects and pairs with the Windows Receiver using a [PairingPayload],
  /// and saves the paired credentials to disk so they survive device shutdown.
  Future<bool> connectWithPayload(
    PairingPayload payload, {
    String clientDeviceName = 'DartPad Android',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await disconnect(stopAutoPair: false);

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
            _connectedServerIp = payload.ip;
            _lastAckTimeMs = _rttClock.elapsedMilliseconds;
            if (_sessionToken != null && !handshakeCompleter.isCompleted) {
              handshakeCompleter.complete(true);
            }
          } else if (ctrl.type == PacketType.reject) {
            if (!handshakeCompleter.isCompleted) {
              handshakeCompleter.complete(false);
            }
          } else if (ctrl.type == PacketType.heartbeatAck) {
            final nowMs = _rttClock.elapsedMilliseconds & 0xFFFFFFFF;
            _lastAckTimeMs = _rttClock.elapsedMilliseconds;
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
      await disconnect(stopAutoPair: false);
      return false;
    }

    _isConnected = true;

    // Persist paired PC info to disk so it automatically reconnects even after phone/PC reboot!
    _settings = _settings.copyWith(
      lastConnectedIp: payload.ip,
      lastConnectedPort: payload.port,
      lastPairedPin: payload.pin,
      lastPairedServerName: _connectedServerName ?? payload.deviceName,
    );
    unawaited(configStore?.saveSettings(_settings) ?? Future.value());

    _sender = LowLatencyInputSender(
      socket: socket,
      targetAddress: targetAddr,
      targetPort: payload.port,
      sessionToken: _sessionToken!,
      updateRateHz: updateRateHz,
    )..startLoop();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Detect silent connection loss (> 4 seconds without heartbeatAck) -> trigger auto-reconnect
      if (_rttClock.elapsedMilliseconds - _lastAckTimeMs > 4000) {
        unawaited(disconnect(stopAutoPair: false));
        return;
      }

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

  /// Handles touch down/up on any layout item:
  /// - Single Button or Simultaneous Combo (`LB + RB`): held while finger is down.
  /// - Sequential Millisecond Macro (`(1)` `X -> Y -> A -> A`): steps through
  ///   each button in order with `item.stepDelayMs` milliseconds per step!
  void handleLayoutItemTouch(String itemId, bool isPressed) {
    final item = _layout.items.where((e) => e.id == itemId).firstOrNull;
    if (item == null || !item.visible || item.actions.isEmpty) return;

    if (item.comboMode == ComboExecutionMode.sequence && item.actions.length > 1) {
      if (isPressed) {
        unawaited(_runSequenceMacro(item));
      }
      return;
    }

    if (isPressed) {
      _activeTouchSources[itemId] = item.actions.toSet();
    } else {
      _activeTouchSources.remove(itemId);
    }

    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Executes an ordered sequence of buttons (e.g., `X -> Y -> A -> A`) with
  /// millisecond timing, properly pulsing repeated buttons so the game detects
  /// every single press in the sequence.
  Future<void> _runSequenceMacro(ButtonLayoutItem item) async {
    _macroRunId++;
    final currentRunId = _macroRunId;
    final sourceKey = 'macro_${item.id}_$currentRunId';
    final stepMs = item.stepDelayMs <= 0 ? 35 : item.stepDelayMs;
    final holdMs = (stepMs * 0.65).round().clamp(16, 500);
    final gapMs = (stepMs - holdMs).clamp(12, 500);

    for (var i = 0; i < item.actions.length; i++) {
      if (_macroRunId != currentRunId) break;
      final btn = item.actions[i];

      // Press button step
      _activeTouchSources[sourceKey] = {btn};
      _recomputeButtonsAndFlush(immediate: true);
      await Future<void>.delayed(Duration(milliseconds: holdMs));

      // Release button step so consecutive identical buttons (e.g. A -> A) register cleanly
      _activeTouchSources.remove(sourceKey);
      _recomputeButtonsAndFlush(immediate: true);
      if (i + 1 < item.actions.length) {
        await Future<void>.delayed(Duration(milliseconds: gapMs));
      }
    }
  }

  /// Directly presses/releases a specific [GamepadButton] (e.g. from 4-way D-Pad zones).
  void handleDirectButton(String sourceKey, GamepadButton button, bool isPressed) {
    if (isPressed) {
      _activeTouchSources[sourceKey] = {button};
    } else {
      _activeTouchSources.remove(sourceKey);
    }
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Sets a set of directional buttons for a given touch source (used by 8-way D-Pad).
  void handleDirectButtonSet(
    String sourceKey,
    Set<GamepadButton> buttons,
  ) {
    if (buttons.isEmpty) {
      _activeTouchSources.remove(sourceKey);
    } else {
      _activeTouchSources[sourceKey] = buttons;
    }
    _recomputeButtonsAndFlush(immediate: true);
  }

  /// Intercepts physical Android Volume Up / Volume Down keys and translates them
  /// into virtual triggers (`LT`/`RT` or custom binding) with `0 ms` dispatch delay.
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

  /// Updates the Left or Right 360° analog stick from raw touch offset (`-1.0 .. 1.0`).
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

  /// Releases all pressed buttons, triggers, and sticks immediately.
  void releaseAllInputs() {
    _macroRunId++;
    _activeTouchSources.clear();
    _pressedHardwareKeys.clear();
    _currentState = ControllerState.neutral;
    _sender?.updateState(_currentState, immediate: true);
    onStateChanged?.call(_currentState);
  }

  /// Cleanly disconnects from the PC Receiver and releases all inputs first.
  Future<void> disconnect({bool stopAutoPair = true}) async {
    if (stopAutoPair) {
      stopAutoConnectLoop();
    }
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

    for (final actions in _activeTouchSources.values) {
      mergedButtons.addAll(actions);
    }

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
      leftStick: _currentState.leftStick,
      rightStick: _currentState.rightStick,
      leftTrigger: lt,
      rightTrigger: rt,
    );

    _sender?.updateState(_currentState, immediate: immediate);
    onStateChanged?.call(_currentState);
  }

  static Future<Set<String>> _collectDiscoveryTargets({String? savedIp}) async {
    final targets = <String>{
      if (savedIp != null && savedIp.isNotEmpty) savedIp,
      '127.0.0.1', // ADB USB reverse / local loopback
      '10.0.2.2', // Android Emulator / USB host bridge
      '192.168.42.129', // Standard Android USB Tethering (RNDIS) PC IP
      '192.168.42.1',
      '192.168.137.1', // Windows Mobile Hotspot gateway
      '192.168.43.1', // Android Wi-Fi Hotspot gateway
    };

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
            targets.add('$prefix.1'); // Subnet gateway
            targets.add('$prefix.255'); // Subnet broadcast (Wi-Fi & USB RNDIS)
          }
        }
      }
    } catch (_) {}

    targets.add('192.168.42.255');
    targets.add('255.255.255.255'); // Wi-Fi / LAN Broadcast
    return targets;
  }
}
