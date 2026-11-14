import 'dart:async';
import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Reliable tactile haptic & game rumble vibration helper for Android.
///
/// Uses `package:vibration` (`Vibrator` / `VibrationEffect` via `VIBRATE` permission)
/// so tactile clicks and PC game force-feedback actually vibrate even when
/// `HapticFeedback.lightImpact()` is suppressed by Android gaming modes.
class DartPadHaptics {
  static bool? _hasVibrator;
  static bool? _hasAmp;
  static bool _initInFlight = false;

  static Future<void> _ensureCapabilities() async {
    if (_hasVibrator != null || _initInFlight) return;
    _initInFlight = true;
    try {
      _hasVibrator = await Vibration.hasVibrator();
      _hasAmp = await Vibration.hasAmplitudeControl();
    } catch (_) {
      _hasVibrator = false;
      _hasAmp = false;
    } finally {
      _initInFlight = false;
    }
  }

  /// Crisp 14ms tactile pulse when touching controller buttons or D-pad directions.
  static void buttonTap({int durationMs = 14, int amplitude = 95}) {
    unawaited(_trigger(durationMs: durationMs, amplitude: amplitude));
  }

  /// Proportional rumble pulse when PC games (or Dashboard Rumble Test) trigger vibration.
  static void gameRumble(RumbleEvent rumble) {
    final peak = rumble.peakIntensity.clamp(0.0, 1.0);
    if (peak <= 0.01) return;
    final dur = rumble.durationMs.clamp(25, 600);
    final amp = (40 + peak * 215).round().clamp(1, 255);
    unawaited(_trigger(durationMs: dur, amplitude: amp));
  }

  static Future<void> _trigger({
    required int durationMs,
    required int amplitude,
  }) async {
    try {
      await _ensureCapabilities();
      if (_hasVibrator == true) {
        if (_hasAmp == true) {
          await Vibration.vibrate(duration: durationMs, amplitude: amplitude);
        } else {
          await Vibration.vibrate(duration: durationMs);
        }
        return;
      }
    } catch (_) {}

    // Fallback when running on platforms/tests without native Vibrator
    try {
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }
}
