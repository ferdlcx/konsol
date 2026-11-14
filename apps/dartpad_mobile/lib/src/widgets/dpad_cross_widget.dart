import 'dart:math' as math;
import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';

import '../utils/haptic_helper.dart';

/// Authentic Xbox-style 8-way Cross D-Pad widget rendered with [CustomPainter].
class DpadCrossWidget extends StatefulWidget {
  final double size;
  final Color accentColor;
  final bool editMode;
  final bool hapticEnabled;
  final void Function(Set<GamepadButton> activeDirections) onDirectionsChanged;

  const DpadCrossWidget({
    super.key,
    required this.size,
    this.accentColor = const Color(0xFFE5E7EB),
    this.editMode = false,
    this.hapticEnabled = true,
    required this.onDirectionsChanged,
  });

  @override
  State<DpadCrossWidget> createState() => _DpadCrossWidgetState();
}

class _DpadCrossWidgetState extends State<DpadCrossWidget> {
  Set<GamepadButton> _pressed = const {};

  void _updateFromOffset(Offset localPos) {
    if (widget.editMode) return;
    final radius = widget.size / 2.0;
    final dx = localPos.dx - radius;
    final dy = localPos.dy - radius;
    final dist = math.sqrt(dx * dx + dy * dy);

    if (dist < radius * 0.16) {
      _setDirections(const {});
      return;
    }

    final nx = dx / dist;
    final ny = dy / dist;
    final dirs = <GamepadButton>{};

    // Threshold ~0.38 allows clean cardinal & diagonal presses
    if (ny < -0.38) dirs.add(GamepadButton.dpadUp);
    if (ny > 0.38) dirs.add(GamepadButton.dpadDown);
    if (nx < -0.38) dirs.add(GamepadButton.dpadLeft);
    if (nx > 0.38) dirs.add(GamepadButton.dpadRight);

    _setDirections(dirs);
  }

  void _setDirections(Set<GamepadButton> next) {
    if (_pressed.length == next.length && _pressed.containsAll(next)) return;
    if (next.isNotEmpty && widget.hapticEnabled) {
      DartPadHaptics.buttonTap(durationMs: 12, amplitude: 85);
    }
    setState(() => _pressed = next);
    widget.onDirectionsChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _updateFromOffset(e.localPosition),
      onPointerMove: (e) => _updateFromOffset(e.localPosition),
      onPointerUp: (_) => _setDirections(const {}),
      onPointerCancel: (_) => _setDirections(const {}),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _DpadCrossPainter(
            pressed: _pressed,
            accentColor: widget.accentColor,
          ),
        ),
      ),
    );
  }
}

class _DpadCrossPainter extends CustomPainter {
  final Set<GamepadButton> pressed;
  final Color accentColor;

  const _DpadCrossPainter({
    required this.pressed,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final arm = w * 0.34;
    final offset = (w - arm) / 2.0;

    // Minimalist matte outer dish circle
    final dishPaint = Paint()
      ..color = const Color(0xFF14161B)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(w / 2, h / 2), w / 2, dishPaint);

    final dishBorder = Paint()
      ..color = const Color(0xFF282C36)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(Offset(w / 2, h / 2), (w / 2) - 1, dishBorder);

    // Cross arms
    final basePaint = Paint()
      ..color = const Color(0xFF20242C)
      ..style = PaintingStyle.fill;

    final vRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(offset, w * 0.06, arm, h * 0.88),
      const Radius.circular(6),
    );
    final hRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.06, offset, w * 0.88, arm),
      const Radius.circular(6),
    );
    canvas.drawRRect(vRect, basePaint);
    canvas.drawRRect(hRect, basePaint);

    final activePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    if (pressed.contains(GamepadButton.dpadUp)) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(offset, w * 0.06, arm, offset - w * 0.04),
          const Radius.circular(6),
        ),
        activePaint,
      );
    }
    if (pressed.contains(GamepadButton.dpadDown)) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              offset, offset + arm, arm, h * 0.94 - (offset + arm)),
          const Radius.circular(6),
        ),
        activePaint,
      );
    }
    if (pressed.contains(GamepadButton.dpadLeft)) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * 0.06, offset, offset - w * 0.04, arm),
          const Radius.circular(6),
        ),
        activePaint,
      );
    }
    if (pressed.contains(GamepadButton.dpadRight)) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              offset + arm, offset, w * 0.94 - (offset + arm), arm),
          const Radius.circular(6),
        ),
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DpadCrossPainter oldDelegate) {
    return oldDelegate.pressed != pressed ||
        oldDelegate.accentColor != accentColor;
  }
}
