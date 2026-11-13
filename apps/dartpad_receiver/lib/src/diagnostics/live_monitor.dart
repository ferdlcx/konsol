import 'package:dartpad_protocol/dartpad_protocol.dart';

import '../network/receiver_server.dart';

/// Formats a live, interactive Controller Button & Axis Monitor for the Windows
/// Receiver EXE so the user can immediately verify whether every button, trigger,
/// volume key, combo button, and analog stick responds with zero delay.
class LiveControllerMonitor {
  final ControllerType preset;

  const LiveControllerMonitor({
    this.preset = ControllerType.xbox,
  });

  /// Renders a compact visual state summary of all buttons and analog axes.
  String formatSnapshot(ReceiverDiagnosticsSnapshot snap) {
    final state = snap.currentState;
    final statusBadge = snap.isConnected
        ? 'ONLINE (${snap.clientDeviceName ?? "Android"} @ ${snap.clientAddress ?? "?"})'
        : 'WAITING FOR CONNECTION / AUTO-RELEASED';

    final pressedLabels = state.buttons
        .map((b) => '${preset.labelFor(b)}[${b.name}]')
        .toList();
    final buttonsText =
        pressedLabels.isEmpty ? '(none)' : pressedLabels.join(' + ');

    final lx = _bar(state.leftStick.x);
    final ly = _bar(state.leftStick.y);
    final rx = _bar(state.rightStick.x);
    final ry = _bar(state.rightStick.y);
    final lt = _triggerBar(state.leftTrigger);
    final rt = _triggerBar(state.rightTrigger);

    final buf = StringBuffer()
      ..writeln('====================================================================')
      ..writeln(' DARTPAD WINDOWS RECEIVER — LIVE CONTROLLER TESTER (${preset.name.toUpperCase()})')
      ..writeln('====================================================================')
      ..writeln(' Status      : $statusBadge')
      ..writeln(' Packet Rate : ${snap.packetsPerSecond} Hz | Loss: ${snap.packetLossPercent.toStringAsFixed(2)}% | Out-of-order dropped: ${snap.droppedOutOfOrder}')
      ..writeln(' Sequence #  : ${snap.lastSequence}')
      ..writeln('--------------------------------------------------------------------')
      ..writeln(' ACTIVE BUTTONS : $buttonsText')
      ..writeln(' LEFT STICK     : X $lx (${state.leftStick.x.toStringAsFixed(2)}) | Y $ly (${state.leftStick.y.toStringAsFixed(2)})')
      ..writeln(' RIGHT STICK    : X $rx (${state.rightStick.x.toStringAsFixed(2)}) | Y $ry (${state.rightStick.y.toStringAsFixed(2)})')
      ..writeln(' TRIGGERS       : LT $lt (${(state.leftTrigger * 100).round()}%) | RT $rt (${(state.rightTrigger * 100).round()}%)')
      ..writeln('====================================================================');

    return buf.toString();
  }

  static String _bar(double value) {
    // value in -1.0 .. 1.0 -> 11 chars wide with center at index 5
    final clamped = value.clamp(-1.0, 1.0);
    final pos = ((clamped + 1.0) * 5).round().clamp(0, 10);
    final chars = List<String>.filled(11, '-');
    chars[5] = '|';
    chars[pos] = '#';
    return '[${chars.join()}]';
  }

  static String _triggerBar(double value) {
    final filled = (value.clamp(0.0, 1.0) * 8).round().clamp(0, 8);
    return '[${'#' * filled}${'.' * (8 - filled)}]';
  }
}
