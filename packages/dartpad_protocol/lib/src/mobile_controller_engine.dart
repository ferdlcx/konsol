import 'dart:async';
import 'dart:convert';
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

/// Represents a discovered Windows PC running `DartPad.exe` on Wi-Fi LAN or USB Tethering.
class DiscoveredReceiver {
  final String ip;
  final int udpPort;
  final int httpPort;
  final String serverName;
  final String? pin;
  final String transportHint;

  const DiscoveredReceiver({
    required this.ip,
    this.udpPort = DartPadProtocolConstants.defaultPort,
    this.httpPort = 42101,
    required this.serverName,
    this.pin,
    this.transportHint = 'Wi-Fi / LAN',
  });

  PairingPayload toPayload({String? overridePin}) => PairingPayload(
        ip: ip,
        port: udpPort,
        httpPort: httpPort,
        pin: overridePin ?? pin ?? '',
        deviceName: serverName,
      );
}

/// Summary of an active network interface on the current device (HP / PC).
class LocalInterfaceInfo {
  final String name;
  final String ip;
  final String kind;

  const LocalInterfaceInfo({
    required this.name,
    required this.ip,
    required this.kind,
  });
}

/// Client-side Input Engine, Macro Sequence Runner, & Multi-Transport Wi-Fi / USB
/// Pairing Manager running on the Android device (`dartpad_mobile`).
class MobileControllerEngine {
  ControllerProfile _profile;
  ControllerLayout _layout;
  DartPadAppSettings _settings;
  final DartPadConfigStore? configStore;
  final int updateRateHz;
  final void Function(ControllerState state)? onStateChanged;
  final void Function(bool connected, double rttMs)? onConnectionChanged;
  final void Function(RumbleEvent rumble)? onRumbleReceived;
  final void Function(List<DiscoveredReceiver> receivers)? onReceiversDiscovered;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  LowLatencyInputSender? _sender;
  WebSocket? _wsControl;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _wsSyncTimer;
  Timer? _heartbeatTimer;
  Timer? _autoConnectTimer;
  bool _isAttemptingAutoConnect = false;
  bool _isManualConnectInFlight = false;
  int _wsSequence = 0;
  int _wsPacketsSent = 0;

  ControllerState _currentState = ControllerState.neutral;
  final Map<String, Set<GamepadButton>> _activeTouchSources = {};
  final Set<HardwareKey> _pressedHardwareKeys = {};
  int _macroRunId = 0;

  bool _isConnected = false;
  String _transportMode = 'Disconnected';
  String? _sessionToken;
  String? _connectedServerName;
  String? _connectedServerIp;
  String? _lastConnectionError;
  double _lastRttMs = 0.0;
  int _heartbeatSeq = 0;
  int _lastAckTimeMs = 0;
  RumbleEvent? _lastRumble;
  List<DiscoveredReceiver> _discoveredReceivers = const [];
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
    this.onReceiversDiscovered,
  })  : _profile = profile ?? ControllerProfile.xboxDefault(),
        _layout = layout ?? ControllerLayout.defaultLandscape(),
        _settings = settings ?? const DartPadAppSettings();

  ControllerProfile get profile => _profile;
  ControllerLayout get layout => _layout;
  DartPadAppSettings get settings => _settings;
  ControllerState get currentState => _currentState;
  bool get isConnected => _isConnected;
  String get transportMode => _transportMode;
  String? get connectedServerName => _connectedServerName;
  String? get connectedServerIp => _connectedServerIp;
  String? get lastConnectionError => _lastConnectionError;
  double get lastRttMs => _lastRttMs;
  int get packetsSent => (_sender?.packetsSent ?? 0) + _wsPacketsSent;
  RumbleEvent? get lastRumble => _lastRumble;
  List<DiscoveredReceiver> get discoveredReceivers => _discoveredReceivers;

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

  /// Reads all active IPv4 network interfaces on this phone (Wi-Fi, USB Tethering, Hotspot).
  static Future<List<LocalInterfaceInfo>> detectLocalInterfaces() async {
    final list = <LocalInterfaceInfo>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        final lower = iface.name.toLowerCase();
        final kind = (lower.contains('rndis') ||
                lower.contains('usb') ||
                lower.contains('ncm') ||
                lower.contains('eth'))
            ? 'USB Tethering / Kabel'
            : (lower.contains('wlan') || lower.contains('wi-fi') || lower.contains('ap'))
                ? 'Wi-Fi'
                : 'Jaringan (${iface.name})';
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
            list.add(
              LocalInterfaceInfo(
                name: iface.name,
                ip: addr.address,
                kind: kind,
              ),
            );
          }
        }
      }
    } catch (_) {}
    return list;
  }

  /// Starts a non-blocking background loop that automatically discovers & pairs
  /// with any Windows PC running `DartPad.exe` over Wi-Fi or USB Tethering.
  void startAutoConnectLoop({
    Duration interval = const Duration(seconds: 4),
  }) {
    stopAutoConnectLoop();
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
    if (_isConnected ||
        _isAttemptingAutoConnect ||
        _isManualConnectInFlight ||
        !_settings.autoPairEnabled) {
      return;
    }
    _isAttemptingAutoConnect = true;
    try {
      await discoverAndAutoConnect(
        port: _settings.lastConnectedPort,
        timeout: const Duration(milliseconds: 1100),
        isBackgroundAuto: true,
      );
    } catch (_) {
    } finally {
      _isAttemptingAutoConnect = false;
    }
  }

  /// Scans Wi-Fi LAN, Ethernet Bridge, & USB Tethering subnets using BOTH
  /// fast unicast UDP probes AND HTTP `/api/info` fallback, returning all live PCs.
  Future<List<DiscoveredReceiver>> discoverReceivers({
    int udpPort = DartPadProtocolConstants.defaultPort,
    int httpPort = 42101,
    Duration timeout = const Duration(milliseconds: 1200),
    bool includeSubnetUnicastSweep = true,
  }) async {
    final foundByIp = <String, DiscoveredReceiver>{};
    final localIfaces = await detectLocalInterfaces();
    final ownIps = localIfaces.map((e) => e.ip).toSet();

    final unicastTargets = <String>{
      if (_settings.lastConnectedIp != null &&
          _settings.lastConnectedIp!.isNotEmpty)
        _settings.lastConnectedIp!,
      '127.0.0.1',
      '10.0.2.2',
      '192.168.42.129',
      '192.168.42.1',
      '192.168.137.1',
      '192.168.43.1',
    };

    final broadcastTargets = <String>{
      '192.168.42.255',
      '255.255.255.255',
    };

    for (final iface in localIfaces) {
      final parts = iface.ip.split('.');
      if (parts.length == 4) {
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
        broadcastTargets.add('$prefix.255');
        unicastTargets.add('$prefix.1');
        if (includeSubnetUnicastSweep) {
          // Sweep full /24 unicast so Wi-Fi <-> Ethernet LAN routers & Android 12+ random
          // USB Tethering subnets NEVER fail due to dropped broadcast packets!
          for (var host = 1; host <= 254; host++) {
            final candidate = '$prefix.$host';
            if (!ownIps.contains(candidate)) {
              unicastTargets.add(candidate);
            }
          }
        }
      }
    }

    String classifyTransport(String ip) {
      for (final iface in localIfaces) {
        final p = iface.ip.split('.');
        if (p.length == 4 && ip.startsWith('${p[0]}.${p[1]}.${p[2]}.')) {
          return iface.kind;
        }
      }
      if (ip == '127.0.0.1') return 'USB ADB';
      if (ip.startsWith('192.168.42.')) return 'USB Tethering';
      return 'Wi-Fi / LAN';
    }

    // 1. Single-socket fast UDP DISCOVER blast across broadcast + unicast targets
    RawDatagramSocket? udpSock;
    StreamSubscription<RawSocketEvent>? udpSub;
    final firstHit = Completer<void>();

    try {
      udpSock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      try {
        udpSock.broadcastEnabled = true;
      } catch (_) {}

      final discoverBytes = PacketCodec.encodeControl(
        ControlPacket(
          type: PacketType.discover,
          sequence: 1,
          timestampMs: _rttClock.elapsedMilliseconds,
        ),
      );

      udpSub = udpSock.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          Datagram? dg;
          while ((dg = udpSock?.receive()) != null) {
            final type = PacketCodec.peekPacketType(dg!.data);
            if (type != PacketType.discoverResponse) continue;
            try {
              final ctrl = PacketCodec.decodeControl(dg.data);
              final pin = ctrl.payload['pin']?.toString();
              final srvName =
                  ctrl.payload['serverName']?.toString() ?? 'Windows PC';
              final srvPort = (ctrl.payload['port'] as num?)?.toInt() ?? udpPort;
              final srvHttp = (ctrl.payload['httpPort'] as num?)?.toInt() ?? httpPort;
              final senderIp = dg.address.address;

              foundByIp[senderIp] = DiscoveredReceiver(
                ip: senderIp,
                udpPort: srvPort,
                httpPort: srvHttp,
                serverName: srvName,
                pin: pin,
                transportHint: classifyTransport(senderIp),
              );
              if (!firstHit.isCompleted) firstHit.complete();
            } catch (_) {}
          }
        },
        onError: (_) {},
      );

      for (final ip in [...broadcastTargets, ...unicastTargets]) {
        final addr = InternetAddress.tryParse(ip);
        if (addr == null) continue;
        try {
          udpSock.send(discoverBytes, addr, udpPort);
        } catch (_) {}
      }

      // Wait briefly for UDP responses; simultaneously probe HTTP /api/info on priority hosts
      final priorityHttpTargets = <String>{
        if (_settings.lastConnectedIp != null &&
            _settings.lastConnectedIp!.isNotEmpty)
          _settings.lastConnectedIp!,
        '127.0.0.1',
        '192.168.42.129',
        '192.168.42.1',
        '192.168.137.1',
        '192.168.43.1',
        ...localIfaces
            .map((e) {
              final p = e.ip.split('.');
              return p.length == 4 ? '${p[0]}.${p[1]}.${p[2]}.1' : '';
            })
            .where((e) => e.isNotEmpty),
      };

      await Future.any([
        firstHit.future.then((_) => Future<void>.delayed(const Duration(milliseconds: 120))),
        Future<void>.delayed(timeout),
      ]);

      // If UDP found nothing (e.g. Windows Firewall dropped UDP or broadcast blocked),
      // run HTTP /api/info sweep across subnet in parallel batches!
      if (foundByIp.isEmpty && includeSubnetUnicastSweep) {
        final httpCandidates = {...priorityHttpTargets, ...unicastTargets}.toList();
        const batchSize = 48;
        for (var i = 0; i < httpCandidates.length && foundByIp.isEmpty; i += batchSize) {
          final slice = httpCandidates.sublist(
            i,
            (i + batchSize > httpCandidates.length) ? httpCandidates.length : i + batchSize,
          );
          await Future.wait(
            slice.map((ip) async {
              final rx = await _probeHttpReceiver(ip, httpPort, classifyTransport(ip));
              if (rx != null) {
                foundByIp[rx.ip] = rx;
              }
            }),
          );
        }
      }
    } catch (_) {
    } finally {
      await udpSub?.cancel();
      udpSock?.close();
    }

    _discoveredReceivers = foundByIp.values.toList();
    onReceiversDiscovered?.call(_discoveredReceivers);
    return _discoveredReceivers;
  }

  Future<DiscoveredReceiver?> _probeHttpReceiver(
    String ip,
    int httpPort,
    String transportHint,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 220);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:$httpPort/api/info'))
          .timeout(const Duration(milliseconds: 260));
      final resp = await req.close().timeout(const Duration(milliseconds: 260));
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['app'] != 'DartPad') return null;
      return DiscoveredReceiver(
        ip: ip,
        udpPort: (json['udpPort'] as num?)?.toInt() ?? DartPadProtocolConstants.defaultPort,
        httpPort: httpPort,
        serverName: json['serverName']?.toString() ?? 'Windows PC',
        pin: json['pin']?.toString(),
        transportHint: transportHint,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Automatically discovers a running `DartPad.exe` PC Receiver over Wi-Fi LAN
  /// OR USB Tethering (RNDIS / Hotspot / ADB) and pairs without manual typing!
  Future<bool> discoverAndAutoConnect({
    int port = DartPadProtocolConstants.defaultPort,
    Duration timeout = const Duration(milliseconds: 1200),
    String clientDeviceName = 'DartPad Android',
    bool isBackgroundAuto = false,
  }) async {
    if (isBackgroundAuto && _isManualConnectInFlight) return false;

    // 1. Try saved PC IP + PIN first if previously paired
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
        timeout: const Duration(milliseconds: 700),
        isBackgroundAuto: isBackgroundAuto,
      );
      if (reconnected) return true;
    }

    if (isBackgroundAuto && _isManualConnectInFlight) return false;

    // 2. Discover across Wi-Fi & USB subnets (UDP + HTTP fallback)
    final receivers = await discoverReceivers(
      udpPort: port,
      timeout: timeout,
      includeSubnetUnicastSweep: true,
    );

    for (final rx in receivers) {
      if (isBackgroundAuto && _isManualConnectInFlight) return false;
      if (rx.pin != null && rx.pin!.isNotEmpty) {
        final ok = await connectWithPayload(
          rx.toPayload(),
          clientDeviceName: clientDeviceName,
          timeout: const Duration(seconds: 2),
          isBackgroundAuto: isBackgroundAuto,
        );
        if (ok) return true;
      }
    }
    return false;
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

  /// Connects using any candidate IP inside [payload], ranking HTTP-reachable IPs
  /// first and seamlessly falling back from UDP to TCP HTTP/WebSocket (`/api/pair`
  /// + `/ws-control`) if router/firewall blocks return UDP packets.
  Future<bool> connectWithPayload(
    PairingPayload payload, {
    String clientDeviceName = 'DartPad Android',
    Duration timeout = const Duration(seconds: 3),
    bool isBackgroundAuto = false,
  }) async {
    if (!isBackgroundAuto) {
      _isManualConnectInFlight = true;
    }
    try {
      _lastConnectionError = null;
      final candidates = payload.candidateIps;
      if (candidates.isEmpty) {
        _lastConnectionError = 'Alamat IP PC kosong.';
        return false;
      }

      // Concurrently probe TCP HTTP /api/info when multiple candidate IPs exist
      // so reachable LAN/Wi-Fi IPs are attempted immediately ahead of dead virtual NICs!
      var orderedCandidates = candidates;
      if (candidates.length > 1) {
        final reachable = <String>[];
        final others = <String>[];
        await Future.wait(
          candidates.map((ip) async {
            final probe = await _probeHttpReceiver(ip, payload.httpPort, 'LAN');
            if (probe != null) {
              reachable.add(ip);
            } else {
              others.add(ip);
            }
          }),
        );
        orderedCandidates = [...reachable, ...others];
      }

      for (final ip in orderedCandidates) {
        final singlePayload = PairingPayload(
          ip: ip,
          port: payload.port,
          httpPort: payload.httpPort,
          pin: payload.pin,
          deviceName: payload.deviceName,
        );
        final ok = await _connectSingleIp(
          singlePayload,
          clientDeviceName: clientDeviceName,
          timeout: timeout,
        );
        if (ok) return true;
        // Stop immediately if PIN was explicitly rejected so we don't try other IPs
        if (_lastConnectionError?.contains('PIN salah') == true) {
          return false;
        }
      }

      _lastConnectionError ??=
          'Tidak ada jawaban dari ${orderedCandidates.join(", ")} (UDP:${payload.port} & HTTP:${payload.httpPort}). Pastikan DartPad.exe berjalan & HP+PC di 1 jaringan Wi-Fi/USB.';
      return false;
    } finally {
      if (!isBackgroundAuto) {
        _isManualConnectInFlight = false;
      }
    }
  }

  Future<bool> _connectSingleIp(
    PairingPayload payload, {
    required String clientDeviceName,
    required Duration timeout,
  }) async {
    await disconnect(stopAutoPair: false);

    final targetAddr = InternetAddress.tryParse(payload.ip);
    if (targetAddr == null) {
      throw FormatException('Alamat IP tidak valid: ${payload.ip}');
    }

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket = socket;

    final handshakeCompleter = Completer<bool>();
    var rejectedReason = '';

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
            rejectedReason =
                ctrl.payload['reason']?.toString() ?? 'PIN salah / ditolak PC';
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

    // Phase 1: Try ultra-low-latency UDP handshake first (LAN round-trip < 10 ms)
    socket.send(connectPacket, targetAddr, payload.port);
    final retry1 = Timer(const Duration(milliseconds: 160), () {
      if (!handshakeCompleter.isCompleted) {
        try {
          socket.send(connectPacket, targetAddr, payload.port);
        } catch (_) {}
      }
    });
    final retry2 = Timer(const Duration(milliseconds: 320), () {
      if (!handshakeCompleter.isCompleted) {
        try {
          socket.send(connectPacket, targetAddr, payload.port);
        } catch (_) {}
      }
    });

    final udpWindow = timeout < const Duration(milliseconds: 520)
        ? timeout
        : const Duration(milliseconds: 520);
    final udpAccepted = await handshakeCompleter.future.timeout(
      udpWindow,
      onTimeout: () => false,
    );
    retry1.cancel();
    retry2.cancel();

    if (udpAccepted && _sessionToken != null) {
      _isConnected = true;
      _transportMode = 'UDP 120Hz';
      _lastConnectionError = null;
      await _savePairedSettings(payload);

      _sender = LowLatencyInputSender(
        socket: socket,
        targetAddress: targetAddr,
        targetPort: payload.port,
        sessionToken: _sessionToken!,
        updateRateHz: updateRateHz,
      )..startLoop();

      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_rttClock.elapsedMilliseconds - _lastAckTimeMs > 12000) {
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
        try {
          _socket?.send(hb, targetAddr, payload.port);
        } catch (_) {}
      });

      onConnectionChanged?.call(true, _lastRttMs);
      return true;
    }

    if (rejectedReason.isNotEmpty) {
      await disconnect(stopAutoPair: false);
      _lastConnectionError = 'Ditolak PC: PIN salah ($rejectedReason).';
      return false;
    }

    // Phase 2: Hybrid TCP HTTP (/api/pair) + WebSocket (/ws-control) fallback!
    // Solves asymmetric/one-way UDP where PC turned green on connect packet
    // but return UDP accept never reached the phone.
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      final wsOk = await _pairViaHttpAndAttachWebSocket(
        payload: payload,
        clientDeviceName: clientDeviceName,
        timeout: timeout,
        retainedUdpSocket: socket,
      );
      if (wsOk) {
        return true;
      }
    } catch (_) {}

    // If neither UDP nor TCP succeeded, notify PC to drop any partial green indicator
    try {
      final disc = PacketCodec.encodeControl(
        ControlPacket(
          type: PacketType.disconnect,
          sequence: 2,
          timestampMs: _rttClock.elapsedMilliseconds,
        ),
      );
      socket.send(disc, targetAddr, payload.port);
    } catch (_) {}

    await disconnect(stopAutoPair: false);
    if (_lastConnectionError?.isEmpty ?? true) {
      _lastConnectionError = null;
    }
    return false;
  }

  Future<bool> _pairViaHttpAndAttachWebSocket({
    required PairingPayload payload,
    required String clientDeviceName,
    required Duration timeout,
    RawDatagramSocket? retainedUdpSocket,
  }) async {
    final httpTimeout =
        timeout < const Duration(milliseconds: 900) ? timeout : const Duration(milliseconds: 1400);
    final client = HttpClient()..connectionTimeout = httpTimeout;
    try {
      final pairSw = Stopwatch()..start();
      final req = await client
          .postUrl(Uri.parse('http://${payload.ip}:${payload.httpPort}/api/pair'))
          .timeout(httpTimeout);
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'pin': payload.pin,
          'deviceName': clientDeviceName,
        }),
      );
      final resp = await req.close().timeout(httpTimeout);
      if (resp.statusCode != 200) return false;

      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['ok'] != true) {
        final reason = json['reason']?.toString() ?? 'PIN salah / ditolak PC';
        _lastConnectionError = 'Ditolak PC: PIN salah ($reason).';
        return false;
      }

      final token = json['sessionToken']?.toString();
      if (token == null || token.isEmpty) return false;

      final wsUri = Uri(
        scheme: 'ws',
        host: payload.ip,
        port: payload.httpPort,
        path: '/ws-control',
        queryParameters: {
          'token': token,
          'pin': payload.pin,
          'name': clientDeviceName,
        },
      );
      final ws = await WebSocket.connect(wsUri.toString()).timeout(httpTimeout);
      _wsControl = ws;
      _wsSequence = 0;
      _wsPacketsSent = 0;

      _sessionToken = token;
      _connectedServerName =
          json['serverName']?.toString() ?? payload.deviceName;
      _connectedServerIp = payload.ip;
      _lastRttMs = pairSw.elapsedMilliseconds.toDouble();
      _lastAckTimeMs = _rttClock.elapsedMilliseconds;
      _isConnected = true;
      _transportMode = retainedUdpSocket != null ? 'Dual UDP+TCP' : 'TCP WebSocket';
      _lastConnectionError = null;

      if (retainedUdpSocket != null) {
        _socket = retainedUdpSocket;
        final targetAddr = InternetAddress.tryParse(payload.ip);
        if (targetAddr != null) {
          _sender = LowLatencyInputSender(
            socket: retainedUdpSocket,
            targetAddress: targetAddr,
            targetPort: payload.port,
            sessionToken: token,
            updateRateHz: updateRateHz,
          )..startLoop();
        }
      }

      _wsSub = ws.listen(
        (dynamic msg) {
          if (msg is! String) return;
          try {
            final data = jsonDecode(msg) as Map<String, dynamic>;
            final mType = data['type']?.toString();
            if (mType == 'pong') {
              _lastAckTimeMs = _rttClock.elapsedMilliseconds;
              final ts = (data['ts'] as num?)?.toInt() ?? 0;
              final diff = _rttClock.elapsedMilliseconds - ts;
              if (diff >= 0 && diff < 10000) {
                _lastRttMs = diff.toDouble();
                onConnectionChanged?.call(_isConnected, _lastRttMs);
              }
            } else if (mType == 'rumble') {
              final rumble = RumbleEvent(
                largeMotor: (data['large'] as num?)?.toDouble() ?? 0.0,
                smallMotor: (data['small'] as num?)?.toDouble() ?? 0.0,
                durationMs: (data['durationMs'] as num?)?.toInt() ?? 80,
              );
              _lastRumble = rumble;
              onRumbleReceived?.call(rumble);
            }
          } catch (_) {}
        },
        onDone: () {
          if (_wsControl == ws && _isConnected) {
            unawaited(disconnect(stopAutoPair: false));
          }
        },
        onError: (_) {
          if (_wsControl == ws && _isConnected) {
            unawaited(disconnect(stopAutoPair: false));
          }
        },
      );

      await _savePairedSettings(payload);

      // 60 Hz keep-alive & binary state sync over WebSocket so PC watchdog stays fed
      _wsSyncTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        _sendWsState(_currentState);
      });

      _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_rttClock.elapsedMilliseconds - _lastAckTimeMs > 12000) {
          unawaited(disconnect(stopAutoPair: false));
          return;
        }
        try {
          _wsControl?.add(
            jsonEncode({
              'type': 'ping',
              'ts': _rttClock.elapsedMilliseconds,
            }),
          );
        } catch (_) {}
      });

      onConnectionChanged?.call(true, _lastRttMs);
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _savePairedSettings(PairingPayload payload) async {
    _settings = _settings.copyWith(
      lastConnectedIp: payload.ip,
      lastConnectedPort: payload.port,
      lastPairedPin: payload.pin,
      lastPairedServerName: _connectedServerName ?? payload.deviceName,
    );
    await (configStore?.saveSettings(_settings) ?? Future.value());
  }

  void _sendWsState(ControllerState state) {
    final ws = _wsControl;
    final token = _sessionToken;
    if (ws == null || token == null) return;
    try {
      _wsSequence = (_wsSequence + 1) & 0xFFFFFFFF;
      final bytes = PacketCodec.encodeInput(
        InputPacket(
          sequence: _wsSequence,
          timestampMs: _rttClock.elapsedMilliseconds & 0xFFFFFFFF,
          flags: PairingPayload.computeSessionFlag(token),
          state: state,
        ),
      );
      ws.add(bytes);
      _wsPacketsSent++;
    } catch (_) {}
  }

  void _flushTransportState({required bool immediate}) {
    if (_sender != null) {
      _sender!.updateState(_currentState, immediate: immediate);
    }
    if (_wsControl != null && immediate) {
      _sendWsState(_currentState);
    }
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

      _activeTouchSources[sourceKey] = {btn};
      _recomputeButtonsAndFlush(immediate: true);
      await Future<void>.delayed(Duration(milliseconds: holdMs));

      _activeTouchSources.remove(sourceKey);
      _recomputeButtonsAndFlush(immediate: true);
      if (i + 1 < item.actions.length) {
        await Future<void>.delayed(Duration(milliseconds: gapMs));
      }
    }
  }

  void handleDirectButton(String sourceKey, GamepadButton button, bool isPressed) {
    if (isPressed) {
      _activeTouchSources[sourceKey] = {button};
    } else {
      _activeTouchSources.remove(sourceKey);
    }
    _recomputeButtonsAndFlush(immediate: true);
  }

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

    _flushTransportState(immediate: true);
    onStateChanged?.call(_currentState);
  }

  void releaseAllInputs() {
    _macroRunId++;
    _activeTouchSources.clear();
    _pressedHardwareKeys.clear();
    _currentState = ControllerState.neutral;
    _flushTransportState(immediate: true);
    onStateChanged?.call(_currentState);
  }

  Future<void> disconnect({bool stopAutoPair = true}) async {
    if (stopAutoPair) {
      stopAutoConnectLoop();
    }
    releaseAllInputs();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _wsSyncTimer?.cancel();
    _wsSyncTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    if (_wsControl != null) {
      try {
        _wsControl!.add(jsonEncode({'type': 'disconnect'}));
        await _wsControl!.close();
      } catch (_) {}
      _wsControl = null;
    }
    _sender?.stopLoop();
    _sender = null;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.close();
    _socket = null;
    _isConnected = false;
    _transportMode = 'Disconnected';
    _sessionToken = null;
    onConnectionChanged?.call(false, 0.0);
    if (!stopAutoPair && _settings.autoPairEnabled) {
      startAutoConnectLoop();
    }
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

    _flushTransportState(immediate: immediate);
    onStateChanged?.call(_currentState);
  }
}
