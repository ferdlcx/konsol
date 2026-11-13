import 'dart:convert';
import 'dart:typed_data';

import 'controller_state.dart';
import 'gamepad_button.dart';

/// Protocol constants and binary packet codec for DartPad UDP communication.
///
/// Binary INPUT Packet Layout (28 bytes total, Little Endian):
/// - Offset 0..1   (uint16) : Magic (`0x4450` = "DP")
/// - Offset 2      (uint8)  : Protocol Version (`1`)
/// - Offset 3      (uint8)  : Packet Type (`PacketType.input.code`)
/// - Offset 4..7   (uint32) : Sequence Number
/// - Offset 8..11  (uint32) : Timestamp (ms, lower 32 bits)
/// - Offset 12..15 (uint32) : Buttons Bitmask
/// - Offset 16..17 (int16)  : Left Stick X (-32767 .. 32767)
/// - Offset 18..19 (int16)  : Left Stick Y (-32767 .. 32767)
/// - Offset 20..21 (int16)  : Right Stick X (-32767 .. 32767)
/// - Offset 22..23 (int16)  : Right Stick Y (-32767 .. 32767)
/// - Offset 24     (uint8)  : Left Trigger (0 .. 255)
/// - Offset 25     (uint8)  : Right Trigger (0 .. 255)
/// - Offset 26..27 (uint16) : Flags / Session Token Checksum (16-bit)
class DartPadProtocolConstants {
  static const int magic = 0x4450; // 'D' 'P'
  static const int version = 1;
  static const int inputPacketSize = 28;
  static const int controlHeaderSize = 12;
  static const int defaultPort = 42100;
}

/// Packet types used in the DartPad UDP handshake and real-time input stream.
enum PacketType {
  discover(0x01),
  discoverResponse(0x02),
  connect(0x03),
  accept(0x04),
  reject(0x05),
  input(0x10),
  heartbeat(0x11),
  heartbeatAck(0x12),
  rumble(0x20),
  disconnect(0xFF);

  final int code;
  const PacketType(this.code);

  static PacketType? fromCode(int code) {
    for (final type in PacketType.values) {
      if (type.code == code) return type;
    }
    return null;
  }
}

/// Decoded 28-byte binary input packet.
class InputPacket {
  final int sequence;
  final int timestampMs;
  final ControllerState state;
  final int flags;

  const InputPacket({
    required this.sequence,
    required this.timestampMs,
    required this.state,
    this.flags = 0,
  });
}

/// Decoded control/handshake packet (`DISCOVER`, `RESPONSE`, `CONNECT`, `ACCEPT`, `HEARTBEAT`, etc.).
class ControlPacket {
  final PacketType type;
  final int sequence;
  final int timestampMs;
  final Map<String, dynamic> payload;

  const ControlPacket({
    required this.type,
    required this.sequence,
    required this.timestampMs,
    this.payload = const {},
  });
}

/// Encoder & decoder for DartPad binary UDP packets.
class PacketCodec {
  const PacketCodec._();

  /// Encodes a 28-byte binary [InputPacket].
  static Uint8List encodeInput(InputPacket packet) {
    final buffer = Uint8List(DartPadProtocolConstants.inputPacketSize);
    encodeInputInto(packet, ByteData.sublistView(buffer));
    return buffer;
  }

  /// Zero-allocation encoder: writes the 28-byte binary [InputPacket] directly into
  /// a pre-allocated [target] `ByteData` buffer (must be at least 28 bytes).
  /// Use this in the 120 Hz loop & instant edge-trigger path to eliminate GC jitter.
  static void encodeInputInto(InputPacket packet, ByteData target) {
    final state = packet.state;

    target.setUint16(0, DartPadProtocolConstants.magic, Endian.little);
    target.setUint8(2, DartPadProtocolConstants.version);
    target.setUint8(3, PacketType.input.code);
    target.setUint32(4, packet.sequence & 0xFFFFFFFF, Endian.little);
    target.setUint32(8, packet.timestampMs & 0xFFFFFFFF, Endian.little);
    target.setUint32(12, state.buttonBitmask, Endian.little);

    target.setInt16(16, _doubleToInt16(state.leftStick.x), Endian.little);
    target.setInt16(18, _doubleToInt16(state.leftStick.y), Endian.little);
    target.setInt16(20, _doubleToInt16(state.rightStick.x), Endian.little);
    target.setInt16(22, _doubleToInt16(state.rightStick.y), Endian.little);

    target.setUint8(24, _doubleToUint8(state.leftTrigger));
    target.setUint8(25, _doubleToUint8(state.rightTrigger));
    target.setUint16(26, packet.flags & 0xFFFF, Endian.little);
  }

  /// Decodes a 28-byte binary [InputPacket].
  /// Throws [FormatException] if magic, version, type, or packet length is invalid.
  static InputPacket decodeInput(Uint8List bytes) {
    if (bytes.length != DartPadProtocolConstants.inputPacketSize) {
      throw FormatException(
        'Invalid INPUT packet length: expected ${DartPadProtocolConstants.inputPacketSize}, got ${bytes.length}',
      );
    }

    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final magic = data.getUint16(0, Endian.little);
    if (magic != DartPadProtocolConstants.magic) {
      throw FormatException('Invalid packet magic: 0x${magic.toRadixString(16)}');
    }

    final version = data.getUint8(2);
    if (version != DartPadProtocolConstants.version) {
      throw FormatException('Unsupported protocol version: $version');
    }

    final typeCode = data.getUint8(3);
    if (typeCode != PacketType.input.code) {
      throw FormatException('Expected INPUT packet (0x10), got 0x${typeCode.toRadixString(16)}');
    }

    final sequence = data.getUint32(4, Endian.little);
    final timestampMs = data.getUint32(8, Endian.little);
    final buttonMask = data.getUint32(12, Endian.little);

    final lx = _int16ToDouble(data.getInt16(16, Endian.little));
    final ly = _int16ToDouble(data.getInt16(18, Endian.little));
    final rx = _int16ToDouble(data.getInt16(20, Endian.little));
    final ry = _int16ToDouble(data.getInt16(22, Endian.little));

    final lt = _uint8ToDouble(data.getUint8(24));
    final rt = _uint8ToDouble(data.getUint8(25));
    final flags = data.getUint16(26, Endian.little);

    return InputPacket(
      sequence: sequence,
      timestampMs: timestampMs,
      flags: flags,
      state: ControllerState(
        buttons: GamepadButton.decodeBitmask(buttonMask),
        leftStick: StickState(x: lx, y: ly),
        rightStick: StickState(x: rx, y: ry),
        leftTrigger: lt,
        rightTrigger: rt,
      ),
    );
  }

  /// Encodes a [ControlPacket] (12-byte header + UTF-8 JSON body).
  static Uint8List encodeControl(ControlPacket packet) {
    final jsonBytes = packet.payload.isEmpty
        ? const <int>[]
        : utf8.encode(jsonEncode(packet.payload));

    final totalLength = DartPadProtocolConstants.controlHeaderSize + jsonBytes.length;
    final bytes = Uint8List(totalLength);
    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );

    data.setUint16(0, DartPadProtocolConstants.magic, Endian.little);
    data.setUint8(2, DartPadProtocolConstants.version);
    data.setUint8(3, packet.type.code);
    data.setUint32(4, packet.sequence & 0xFFFFFFFF, Endian.little);
    data.setUint32(8, packet.timestampMs & 0xFFFFFFFF, Endian.little);

    if (jsonBytes.isNotEmpty) {
      bytes.setRange(DartPadProtocolConstants.controlHeaderSize, totalLength, jsonBytes);
    }

    return bytes;
  }

  /// Decodes a [ControlPacket].
  static ControlPacket decodeControl(Uint8List bytes) {
    if (bytes.length < DartPadProtocolConstants.controlHeaderSize) {
      throw FormatException(
        'Control packet too short: ${bytes.length} bytes',
      );
    }

    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final magic = data.getUint16(0, Endian.little);
    if (magic != DartPadProtocolConstants.magic) {
      throw FormatException('Invalid packet magic: 0x${magic.toRadixString(16)}');
    }

    final version = data.getUint8(2);
    if (version != DartPadProtocolConstants.version) {
      throw FormatException('Unsupported protocol version: $version');
    }

    final typeCode = data.getUint8(3);
    final type = PacketType.fromCode(typeCode);
    if (type == null || type == PacketType.input) {
      throw FormatException('Invalid control packet type: 0x${typeCode.toRadixString(16)}');
    }

    final sequence = data.getUint32(4, Endian.little);
    final timestampMs = data.getUint32(8, Endian.little);

    var payload = <String, dynamic>{};
    if (bytes.length > DartPadProtocolConstants.controlHeaderSize) {
      final bodyBytes = bytes.sublist(DartPadProtocolConstants.controlHeaderSize);
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map<String, dynamic>) {
        payload = decoded;
      }
    }

    return ControlPacket(
      type: type,
      sequence: sequence,
      timestampMs: timestampMs,
      payload: payload,
    );
  }

  /// Peeks at the packet type of raw incoming UDP bytes without full decoding.
  /// Returns `null` if the header magic or version is invalid.
  static PacketType? peekPacketType(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    if (data.getUint16(0, Endian.little) != DartPadProtocolConstants.magic) {
      return null;
    }
    if (data.getUint8(2) != DartPadProtocolConstants.version) {
      return null;
    }
    return PacketType.fromCode(data.getUint8(3));
  }

  static int _doubleToInt16(double value) {
    final clamped = value.clamp(-1.0, 1.0);
    return (clamped * 32767.0).round().clamp(-32767, 32767);
  }

  static double _int16ToDouble(int value) {
    return (value / 32767.0).clamp(-1.0, 1.0);
  }

  static int _doubleToUint8(double value) {
    final clamped = value.clamp(0.0, 1.0);
    return (clamped * 255.0).round().clamp(0, 255);
  }

  static double _uint8ToDouble(int value) {
    return (value / 255.0).clamp(0.0, 1.0);
  }
}
