import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartpad_protocol/dartpad_protocol.dart';

import '../controller/watchdog.dart';
import '../virtual_device/gamepad_provider.dart';

/// Event emitted whenever the receiver processes an input state or connection change.
/// Used by the EXE Live Button Tester / Dashboard to verify button responses in real time.
class ReceiverDiagnosticsSnapshot {
  final bool isConnected;
  final String? clientAddress;
  final String? clientDeviceName;
  final ControllerState currentState;
  final int packetsPerSecond;
  final double packetLossPercent;
  final int droppedOutOfOrder;
  final int lastSequence;

  const ReceiverDiagnosticsSnapshot({
    required this.isConnected,
    this.clientAddress,
    this.clientDeviceName,
    required this.currentState,
    required this.packetsPerSecond,
    required this.packetLossPercent,
    required this.droppedOutOfOrder,
    required this.lastSequence,
  });
}

/// Low-latency UDP Receiver Server for Windows PC.
///
/// Handles:
/// - QR Code & 6-digit PIN pairing (`PairingPayload`).
/// - LAN Broadcast discovery (`DISCOVER` -> `RESPONSE`).
/// - Authenticated session token + 16-bit session flag verification.
/// - Immediate zero-delay forwarding of 28-byte `INPUT` packets to [GamepadProvider].
/// - Out-of-order UDP packet rejection via [SequenceTracker].
/// - Auto-release safety via [InputWatchdog] when connection drops.
class DartPadReceiverServer {
  final int port;
  final String serverName;
  final GamepadProvider gamepadProvider;
  final Duration watchdogTimeout;
  final void Function(ReceiverDiagnosticsSnapshot snapshot)? onDiagnosticsUpdate;
  void Function(RumbleEvent rumble)? onRumbleGenerated;

  late final String _pairingPin;
  String? _activeSessionToken;
  int? _activeSessionFlag;
  InternetAddress? _connectedClientAddress;
  int? _connectedClientPort;
  String? _connectedClientName;

  RawDatagramSocket? _socket;
  late final InputWatchdog _watchdog;
  final SequenceTracker _sequenceTracker = SequenceTracker();

  ControllerState _currentState = ControllerState.neutral;
  int _packetsInCurrentWindow = 0;
  int _lastMeasuredPps = 0;
  int _lastSequence = 0;
  Timer? _ppsTimer;

  DartPadReceiverServer({
    this.port = DartPadProtocolConstants.defaultPort,
    this.serverName = 'DartPad-PC',
    required this.gamepadProvider,
    this.watchdogTimeout = const Duration(milliseconds: 200),
    String? customPin,
    this.onDiagnosticsUpdate,
    this.onRumbleGenerated,
  }) : _pairingPin = customPin ?? _generatePin() {
    _watchdog = InputWatchdog(
      timeout: watchdogTimeout,
      onTimeout: _handleWatchdogTimeout,
    );
  }

  String get pairingPin => _pairingPin;
  bool get isClientConnected => _activeSessionFlag != null;
  String? get activeSessionToken => _activeSessionToken;
  int? get activeSessionFlag => _activeSessionFlag;
  ControllerState get currentState => _currentState;
  SequenceTracker get sequenceTracker => _sequenceTracker;
  int get boundPort => _socket?.port ?? port;

  int advertisedHttpPort = 42101;

  bool isValidSessionToken(String? token) =>
      token != null &&
      token.isNotEmpty &&
      _activeSessionToken != null &&
      token == _activeSessionToken;

  /// Pairs a remote controller over TCP HTTP (`POST /api/pair`), solving
  /// one-way / asymmetric UDP issues where PC turns green while phone gets no reply.
  Map<String, dynamic> handleHttpPair({
    required String pin,
    String deviceName = 'Android Controller',
    String? clientAddress,
  }) {
    if (pin.trim() != _pairingPin) {
      return {
        'ok': false,
        'reason': 'Invalid pairing PIN',
      };
    }

    _activeSessionToken =
        'sess_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
    _activeSessionFlag =
        PairingPayload.computeSessionFlag(_activeSessionToken!);
    if (clientAddress != null) {
      final parsed = InternetAddress.tryParse(clientAddress);
      if (parsed != null) {
        _connectedClientAddress = parsed;
        _connectedClientPort ??= 0;
      }
    }
    _connectedClientName =
        deviceName.trim().isEmpty ? 'Android Controller' : deviceName.trim();
    _sequenceTracker.reset();
    _watchdog.feed();
    _emitSnapshot();

    return {
      'ok': true,
      'sessionToken': _activeSessionToken,
      'sessionFlag': _activeSessionFlag,
      'serverName': serverName,
      'udpPort': boundPort,
      'httpPort': advertisedHttpPort,
    };
  }

  /// Unpairs an HTTP/WebSocket session cleanly and resets virtual gamepad to neutral.
  void handleHttpUnpair() {
    _resetToNeutralAndDisconnect();
  }

  /// Accepts controller state from non-UDP transports (such as TCP WebSocket `/ws-control`
  /// or the zero-install Web Gamepad `/pad`) and forwards it to the virtual gamepad driver.
  void handleExternalInputState(
    ControllerState state, {
    int? sequence,
    String? clientAddress,
    String? clientDeviceName,
  }) {
    if (_activeSessionFlag == null) {
      _activeSessionToken ??=
          'sess_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
      _activeSessionFlag =
          PairingPayload.computeSessionFlag(_activeSessionToken!);
    }
    if (clientAddress != null && _connectedClientAddress == null) {
      final parsed = InternetAddress.tryParse(clientAddress);
      if (parsed != null) {
        _connectedClientAddress = parsed;
        _connectedClientPort ??= 0;
      }
    }
    if (clientDeviceName != null && clientDeviceName.trim().isNotEmpty) {
      _connectedClientName = clientDeviceName.trim();
    }

    _watchdog.feed();
    _packetsInCurrentWindow++;
    if (sequence != null) {
      _lastSequence = sequence;
    } else {
      _lastSequence = (_lastSequence + 1) & 0xFFFFFFFF;
    }
    _currentState = state;
    gamepadProvider.update(_currentState);

    final driverRumble = gamepadProvider.pollRumble();
    if (driverRumble != null) {
      sendRumbleToClient(driverRumble);
    }

    _emitSnapshot();
  }

  /// Generates the [PairingPayload] (for QR Code & manual pairing) for local PC IPs.
  PairingPayload buildPairingPayload(
    String localIp, {
    List<String> allIps = const [],
    int httpPort = 42101,
  }) {
    return PairingPayload(
      ip: localIp,
      allIps: allIps,
      port: boundPort,
      httpPort: httpPort,
      pin: _pairingPin,
      deviceName: serverName,
    );
  }

  /// Starts the UDP server and initializes the virtual gamepad provider.
  Future<void> start({InternetAddress? bindAddress}) async {
    gamepadProvider.init();
    _socket = await RawDatagramSocket.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      port,
    );
    try {
      _socket!.broadcastEnabled = true;
    } catch (_) {}

    _socket!.listen(_onSocketEvent);

    _ppsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _lastMeasuredPps = _packetsInCurrentWindow;
      _packetsInCurrentWindow = 0;
      _emitSnapshot();
    });
  }

  /// Stops the UDP server, stops the watchdog, and resets/disposes the virtual gamepad.
  Future<void> stop() async {
    _ppsTimer?.cancel();
    _ppsTimer = null;
    _watchdog.stop();
    gamepadProvider.reset();
    gamepadProvider.dispose();
    _socket?.close();
    _socket = null;
    _activeSessionToken = null;
    _activeSessionFlag = null;
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;

    // Drain all available datagrams in the OS socket buffer immediately
    // so queued packets never wait for the next event loop turn.
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _processDatagram(datagram!);
    }
  }

  void _processDatagram(Datagram datagram) {
    final bytes = datagram.data;
    final packetType = PacketCodec.peekPacketType(bytes);
    if (packetType == null) return;

    if (packetType == PacketType.input) {
      _handleInputPacket(datagram);
    } else {
      _handleControlPacket(datagram);
    }
  }

  void _handleInputPacket(Datagram datagram) {
    final expectedFlag = _activeSessionFlag;
    if (expectedFlag == null) return; // Ignore input before pairing handshake

    try {
      final packet = PacketCodec.decodeInput(datagram.data);

      // Verify 16-bit session flag to prevent unauthorized LAN injection
      if (packet.flags != expectedFlag) return;

      // Drop out-of-order / duplicate UDP packets so stale state never overwrites newer state
      if (!_sequenceTracker.accept(packet.sequence)) return;

      _watchdog.feed();
      _packetsInCurrentWindow++;
      _lastSequence = packet.sequence;
      _currentState = packet.state;

      // Push immediately to the virtual gamepad driver
      gamepadProvider.update(_currentState);

      // Check if the PC game / driver emitted a Force Feedback / Rumble event
      final driverRumble = gamepadProvider.pollRumble();
      if (driverRumble != null) {
        sendRumbleToClient(driverRumble);
      }

      _emitSnapshot();
    } on FormatException {
      // Ignore malformed packets
    }
  }

  /// Sends a Force Feedback / [RumbleEvent] over UDP & any connected WebSocket controllers
  /// so the phone vibrates in sync with the PC game (or during a controller vibration test).
  bool sendRumbleToClient(RumbleEvent rumble) {
    onRumbleGenerated?.call(rumble);
    final socket = _socket;
    final addr = _connectedClientAddress;
    final port = _connectedClientPort;
    if (socket == null ||
        addr == null ||
        port == null ||
        port <= 0 ||
        !isClientConnected) {
      return isClientConnected;
    }

    _lastSequence = (_lastSequence + 1) & 0xFFFFFFFF;
    final packet = rumble.toControlPacket(
      sequence: _lastSequence,
      timestampMs: DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF,
    );
    final bytes = PacketCodec.encodeControl(packet);
    socket.send(bytes, addr, port);
    return true;
  }

  void _handleControlPacket(Datagram datagram) {
    try {
      final control = PacketCodec.decodeControl(datagram.data);
      switch (control.type) {
        case PacketType.discover:
          final response = PacketCodec.encodeControl(
            ControlPacket(
              type: PacketType.discoverResponse,
              sequence: control.sequence,
              timestampMs: control.timestampMs,
              payload: {
                'serverName': serverName,
                'port': boundPort,
                'httpPort': advertisedHttpPort,
                'pin': _pairingPin,
              },
            ),
          );
          _socket?.send(response, datagram.address, datagram.port);
          break;

        case PacketType.connect:
          final clientPin = control.payload['pin']?.toString() ?? '';
          if (clientPin != _pairingPin) {
            final reject = PacketCodec.encodeControl(
              ControlPacket(
                type: PacketType.reject,
                sequence: control.sequence,
                timestampMs: control.timestampMs,
                payload: {'reason': 'Invalid pairing PIN'},
              ),
            );
            _socket?.send(reject, datagram.address, datagram.port);
            return;
          }

          _activeSessionToken =
              'sess_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
          _activeSessionFlag =
              PairingPayload.computeSessionFlag(_activeSessionToken!);
          _connectedClientAddress = datagram.address;
          _connectedClientPort = datagram.port;
          _connectedClientName =
              control.payload['deviceName']?.toString() ?? 'Android Controller';
          _sequenceTracker.reset();
          _watchdog.feed();

          final accept = PacketCodec.encodeControl(
            ControlPacket(
              type: PacketType.accept,
              sequence: control.sequence,
              timestampMs: control.timestampMs,
              payload: {
                'sessionToken': _activeSessionToken,
                'sessionFlag': _activeSessionFlag,
                'serverName': serverName,
              },
            ),
          );
          _socket?.send(accept, datagram.address, datagram.port);
          _emitSnapshot();
          break;

        case PacketType.heartbeat:
          if (_activeSessionFlag != null) {
            _watchdog.feed();
            final ack = PacketCodec.encodeControl(
              ControlPacket(
                type: PacketType.heartbeatAck,
                sequence: control.sequence,
                timestampMs: control.timestampMs,
              ),
            );
            _socket?.send(ack, datagram.address, datagram.port);
          }
          break;

        case PacketType.disconnect:
          _resetToNeutralAndDisconnect();
          break;

        default:
          break;
      }
    } on FormatException {
      // Ignore malformed control packets
    }
  }

  void _handleWatchdogTimeout() {
    // Auto-release all buttons immediately if connection drops!
    _currentState = ControllerState.neutral;
    gamepadProvider.reset();
    _emitSnapshot();
  }

  void _resetToNeutralAndDisconnect() {
    _watchdog.stop();
    _currentState = ControllerState.neutral;
    gamepadProvider.reset();
    _activeSessionToken = null;
    _activeSessionFlag = null;
    _connectedClientAddress = null;
    _connectedClientPort = null;
    _connectedClientName = null;
    _emitSnapshot();
  }

  void _emitSnapshot() {
    onDiagnosticsUpdate?.call(
      ReceiverDiagnosticsSnapshot(
        isConnected: isClientConnected && !_watchdog.isTimedOut,
        clientAddress: _connectedClientAddress != null
            ? '${_connectedClientAddress!.address}:${_connectedClientPort ?? 0}'
            : null,
        clientDeviceName: _connectedClientName,
        currentState: _currentState,
        packetsPerSecond: _lastMeasuredPps,
        packetLossPercent: _sequenceTracker.packetLossRatio * 100.0,
        droppedOutOfOrder: _sequenceTracker.droppedOutOfOrder,
        lastSequence: _lastSequence,
      ),
    );
  }

  static String _generatePin() {
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final dir = Directory('$home/.dartpad')..createSync(recursive: true);
        final pinFile = File('${dir.path}/receiver_pin.txt');
        if (pinFile.existsSync()) {
          final saved = pinFile.readAsStringSync().trim();
          if (saved.length == 6 && int.tryParse(saved) != null) {
            return saved;
          }
        }
        final rnd = Random.secure();
        final newPin = (100000 + rnd.nextInt(900000)).toString();
        pinFile.writeAsStringSync(newPin);
        return newPin;
      }
    } catch (_) {}
    final rnd = Random.secure();
    return (100000 + rnd.nextInt(900000)).toString();
  }
}
