import 'dart:async';
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
  bool _showConnectionScreen = false;

  @override
  void initState() {
    super.initState();
    final persistentStore = DartPadConfigStore.defaultPersistentStore();
    _engine = MobileControllerEngine(
      profile: ControllerProfile.xboxDefault(),
      layout: ControllerLayout.defaultLandscape(),
      configStore: persistentStore,
      updateRateHz: 120,
      onRumbleReceived: _handleGameRumble,
      onConnectionChanged: (_, __) {
        if (mounted) setState(() {});
      },
    );

    // Load saved layout, combo buttons, theme, scale, and paired PC from disk
    // and start automatic Wi-Fi + USB discovery/pairing in the background!
    unawaited(
      _engine.initializeFromDisk(startBackgroundAutoPair: true).then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  void _handleGameRumble(RumbleEvent rumble) {
    if (!_engine.settings.hapticFeedback || rumble.isSilent) return;
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
    final themePreset = _engine.settings.themePreset;

    return MaterialApp(
      title: 'DartPad Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Color(themePreset.bgHex),
        colorScheme: ColorScheme.dark(
          primary: Color(themePreset.primaryHex),
          secondary: Color(themePreset.accentHex),
        ),
      ),
      home: _showConnectionScreen
          ? ConnectionScreen(
              engine: _engine,
              onBackToController: () {
                setState(() => _showConnectionScreen = false);
              },
            )
          : ControllerScreen(
              engine: _engine,
              onOpenConnectionScreen: () {
                setState(() => _showConnectionScreen = true);
              },
            ),
    );
  }
}
