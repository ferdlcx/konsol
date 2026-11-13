import 'package:dartpad_protocol/dartpad_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/screens/connection_screen.dart';
import 'src/screens/controller_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DartPadMobileApp());
}

class DartPadMobileApp extends StatefulWidget {
  const DartPadMobileApp({super.key});

  @override
  State<DartPadMobileApp> createState() => _DartPadMobileAppState();
}

class _DartPadMobileAppState extends State<DartPadMobileApp> {
  late final MobileControllerEngine _engine;
  bool _showController = false;

  @override
  void initState() {
    super.initState();
    _engine = MobileControllerEngine(
      profile: ControllerProfile.xboxDefault(),
      layout: ControllerLayout.defaultLandscape(),
      updateRateHz: 120,
      onRumbleReceived: _handleGameRumble,
    );
  }

  /// Translates incoming PC Game Force Feedback ([RumbleEvent]) into physical
  /// phone vibration intensity (Heavy, Medium, or Light impact).
  void _handleGameRumble(RumbleEvent rumble) {
    if (rumble.isSilent) return;
    final peak = rumble.peakIntensity;
    if (peak >= 0.70) {
      HapticFeedback.heavyImpact();
    } else if (peak >= 0.35) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
  }

  @override
  void dispose() {
    _engine.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DartPad Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFF4081),
        ),
      ),
      home: _showController
          ? ControllerScreen(
              engine: _engine,
              onOpenConnectionSettings: () {
                setState(() => _showController = false);
              },
            )
          : ConnectionScreen(
              engine: _engine,
              onConnected: () {
                setState(() => _showController = true);
              },
            ),
    );
  }
}
