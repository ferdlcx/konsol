import 'dart:math' as math;
import 'package:flutter/material.dart';

/// High-precision 360-degree virtual analog joystick rendered via [CustomPainter].
///
/// Features:
/// - Smooth 360° vector tracking with center snap-back on release.
/// - Visual radial deadzone ring + circular boundary ring.
/// - Zero-lag pointer event dispatch directly to [onStickChanged].
class VirtualJoystickWidget extends StatefulWidget {
  final double size;
  final double deadzone;
  final Color accentColor;
  final String label;
  final bool editMode;
  final void Function(double rawX, double rawY) onStickChanged;

  const VirtualJoystickWidget({
    super.key,
    this.size = 150.0,
    this.deadzone = 0.08,
    this.accentColor = const Color(0xFF00E5FF),
    this.label = 'LS',
    this.editMode = false,
    required this.onStickChanged,
  });

  @override
  State<VirtualJoystickWidget> createState() => _VirtualJoystickWidgetState();
}

class _VirtualJoystickWidgetState extends State<VirtualJoystickWidget> {
  Offset _knobOffset = Offset.zero; // normalized -1.0 .. 1.0
  bool _isDragging = false;

  void _updateFromLocalPosition(Offset localPosition) {
    if (widget.editMode) return;
    final radius = widget.size / 2.0;
    final center = Offset(radius, radius);
    final delta = localPosition - center;
    final distance = delta.distance;

    Offset normalized;
    if (distance == 0.0) {
      normalized = Offset.zero;
    } else {
      final clampedDist = math.min(distance, radius);
      final ratio = clampedDist / radius;
      normalized = Offset(
        (delta.dx / distance) * ratio,
        // Invert Y so pushing up yields +1.0 and down yields -1.0
        -(delta.dy / distance) * ratio,
      );
    }

    setState(() {
      _isDragging = true;
      _knobOffset = normalized;
    });
    widget.onStickChanged(normalized.dx, normalized.dy);
  }

  void _resetCenter() {
    if (widget.editMode) return;
    setState(() {
      _isDragging = false;
      _knobOffset = Offset.zero;
    });
    widget.onStickChanged(0.0, 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _updateFromLocalPosition(e.localPosition),
      onPointerMove: (e) => _updateFromLocalPosition(e.localPosition),
      onPointerUp: (_) => _resetCenter(),
      onPointerCancel: (_) => _resetCenter(),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _JoystickPainter(
            knobOffset: _knobOffset,
            deadzone: widget.deadzone,
            accentColor: widget.accentColor,
            isDragging: _isDragging,
            label: widget.label,
          ),
        ),
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset knobOffset;
  final double deadzone;
  final Color accentColor;
  final bool isDragging;
  final String label;

  const _JoystickPainter({
    required this.knobOffset,
    required this.deadzone,
    required this.accentColor,
    required this.isDragging,
    required this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;

    // 1. Outer base circle (dark gaming utility style)
    final basePaint = Paint()
      ..color = const Color(0xCC141923)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerRadius, basePaint);

    // 2. Outer glowing border
    final borderPaint = Paint()
      ..color = isDragging ? accentColor : accentColor.withValues(alpha: 0.35)
      ..strokeWidth = isDragging ? 2.5 : 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, outerRadius - 1.5, borderPaint);

    // 3. Deadzone ring indicator
    final deadzonePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, outerRadius * deadzone.clamp(0.02, 0.5), deadzonePaint);

    // 4. Crosshair lines
    final crossPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(center.dx - outerRadius * 0.7, center.dy),
      Offset(center.dx + outerRadius * 0.7, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - outerRadius * 0.7),
      Offset(center.dx, center.dy + outerRadius * 0.7),
      crossPaint,
    );

    // 5. Thumb stick knob position
    final maxKnobTravel = outerRadius * 0.65;
    final knobCenter = Offset(
      center.dx + knobOffset.dx * maxKnobTravel,
      center.dy - knobOffset.dy * maxKnobTravel,
    );

    final knobPaint = Paint()
      ..color = isDragging
          ? accentColor.withValues(alpha: 0.90)
          : const Color(0xFF252D3D)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(knobCenter, outerRadius * 0.34, knobPaint);

    final knobRingPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(knobCenter, outerRadius * 0.34, knobRingPaint);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset ||
        oldDelegate.isDragging != isDragging ||
        oldDelegate.deadzone != deadzone ||
        oldDelegate.accentColor != accentColor;
  }
}
