import 'dart:convert';
import 'dart:io';

import 'controller_layout.dart';
import 'controller_profile.dart';

/// Available minimalist matte color themes for the DartPad Android Controller UI.
enum DartPadThemePreset {
  obsidian(
    id: 'obsidian',
    name: 'Obsidian Minimal',
    bgHex: 0xFF0E0F12,
    panelHex: 0xFF16181D,
    primaryHex: 0xFF282D37,
    accentHex: 0xFFE5E7EB,
  ),
  nordicSlate(
    id: 'nordic_slate',
    name: 'Nordic Steel',
    bgHex: 0xFF0F1419,
    panelHex: 0xFF171E26,
    primaryHex: 0xFF263342,
    accentHex: 0xFF60A5FA,
  ),
  graphiteAmber(
    id: 'graphite_amber',
    name: 'Graphite Warm',
    bgHex: 0xFF111214,
    panelHex: 0xFF191B1F,
    primaryHex: 0xFF2E2920,
    accentHex: 0xFFF59E0B,
  ),
  oledMono(
    id: 'oled_mono',
    name: 'AMOLED Pure',
    bgHex: 0xFF000000,
    panelHex: 0xFF111114,
    primaryHex: 0xFF26262B,
    accentHex: 0xFFFFFFFF,
  );

  final String id;
  final String name;
  final int bgHex;
  final int panelHex;
  final int primaryHex;
  final int accentHex;

  const DartPadThemePreset({
    required this.id,
    required this.name,
    required this.bgHex,
    required this.panelHex,
    required this.primaryHex,
    required this.accentHex,
  });

  static DartPadThemePreset fromId(String? id) {
    for (final preset in DartPadThemePreset.values) {
      if (preset.id == id) return preset;
    }
    return DartPadThemePreset.obsidian;
  }
}

/// Application settings stored persistently in `DartPad/settings/app_settings.json`
/// so all customizations and paired PC credentials survive phone/PC reboots.
class DartPadAppSettings {
  static const String appVersion = '0.3.1';
  static const String releaseDate = '2026-11-14';
  static const String releaseUrl =
      'https://github.com/ferdlcx/konsol/releases/tag/v0.3.1';
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/ferdlcx/konsol/releases/latest';

  final int updateRateHz;
  final bool autoReconnect;
  final bool autoPairEnabled;
  final bool hapticFeedback;
  final bool landscapeLock;
  final bool keepScreenAwake;
  final String themeId;
  final double globalScale;
  final String activeProfileId;
  final String activeLayoutId;
  final String? lastConnectedIp;
  final int lastConnectedPort;
  final String? lastPairedPin;
  final String? lastPairedServerName;

  const DartPadAppSettings({
    this.updateRateHz = 120,
    this.autoReconnect = true,
    this.autoPairEnabled = true,
    this.hapticFeedback = true,
    this.landscapeLock = true,
    this.keepScreenAwake = true,
    this.themeId = 'obsidian',
    this.globalScale = 1.0,
    this.activeProfileId = 'xbox_default',
    this.activeLayoutId = 'xbox_authentic_v3',
    this.lastConnectedIp,
    this.lastConnectedPort = 42100,
    this.lastPairedPin,
    this.lastPairedServerName,
  });

  DartPadThemePreset get themePreset => DartPadThemePreset.fromId(themeId);

  DartPadAppSettings copyWith({
    int? updateRateHz,
    bool? autoReconnect,
    bool? autoPairEnabled,
    bool? hapticFeedback,
    bool? landscapeLock,
    bool? keepScreenAwake,
    String? themeId,
    double? globalScale,
    String? activeProfileId,
    String? activeLayoutId,
    String? lastConnectedIp,
    int? lastConnectedPort,
    String? lastPairedPin,
    String? lastPairedServerName,
  }) {
    return DartPadAppSettings(
      updateRateHz: updateRateHz ?? this.updateRateHz,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      autoPairEnabled: autoPairEnabled ?? this.autoPairEnabled,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      landscapeLock: landscapeLock ?? this.landscapeLock,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      themeId: themeId ?? this.themeId,
      globalScale: (globalScale ?? this.globalScale).clamp(0.55, 1.65),
      activeProfileId: activeProfileId ?? this.activeProfileId,
      activeLayoutId: activeLayoutId ?? this.activeLayoutId,
      lastConnectedIp: lastConnectedIp ?? this.lastConnectedIp,
      lastConnectedPort: lastConnectedPort ?? this.lastConnectedPort,
      lastPairedPin: lastPairedPin ?? this.lastPairedPin,
      lastPairedServerName: lastPairedServerName ?? this.lastPairedServerName,
    );
  }

  Map<String, dynamic> toJson() => {
        'updateRateHz': updateRateHz,
        'autoReconnect': autoReconnect,
        'autoPairEnabled': autoPairEnabled,
        'hapticFeedback': hapticFeedback,
        'landscapeLock': landscapeLock,
        'keepScreenAwake': keepScreenAwake,
        'themeId': themeId,
        'globalScale': globalScale,
        'activeProfileId': activeProfileId,
        'activeLayoutId': activeLayoutId,
        if (lastConnectedIp != null) 'lastConnectedIp': lastConnectedIp,
        'lastConnectedPort': lastConnectedPort,
        if (lastPairedPin != null) 'lastPairedPin': lastPairedPin,
        if (lastPairedServerName != null)
          'lastPairedServerName': lastPairedServerName,
      };

  factory DartPadAppSettings.fromJson(Map<String, dynamic> json) {
    final rawLayout =
        (json['activeLayoutId'] as String?) ?? 'xbox_authentic_v3';
    final migratedLayout = rawLayout == 'xbox_authentic_v2'
        ? 'xbox_authentic_v3'
        : rawLayout;
    final rawTheme = (json['themeId'] as String?) ?? 'obsidian';
    final validTheme = DartPadThemePreset.values.any((t) => t.id == rawTheme)
        ? rawTheme
        : 'obsidian';

    return DartPadAppSettings(
      updateRateHz: (json['updateRateHz'] as int?) ?? 120,
      autoReconnect: (json['autoReconnect'] as bool?) ?? true,
      autoPairEnabled: (json['autoPairEnabled'] as bool?) ?? true,
      hapticFeedback: (json['hapticFeedback'] as bool?) ?? true,
      landscapeLock: (json['landscapeLock'] as bool?) ?? true,
      keepScreenAwake: (json['keepScreenAwake'] as bool?) ?? true,
      themeId: validTheme,
      globalScale:
          ((json['globalScale'] as num?)?.toDouble() ?? 1.0).clamp(0.55, 1.65),
      activeProfileId: (json['activeProfileId'] as String?) ?? 'xbox_default',
      activeLayoutId: migratedLayout,
      lastConnectedIp: json['lastConnectedIp'] as String?,
      lastConnectedPort: (json['lastConnectedPort'] as int?) ?? 42100,
      lastPairedPin: json['lastPairedPin'] as String?,
      lastPairedServerName: json['lastPairedServerName'] as String?,
    );
  }
}

/// Manages persistent local JSON configuration files so layouts, combos,
/// themes, and paired PC connection data survive app restarts and device reboots.
class DartPadConfigStore {
  final Directory rootDirectory;

  DartPadConfigStore(this.rootDirectory);

  /// Resolves a persistent user data directory on Android, Windows, or Linux
  /// without requiring external native plugins.
  factory DartPadConfigStore.defaultPersistentStore({
    String androidPackageName = 'com.ferdlcx.dartpad.dartpad_mobile',
  }) {
    if (Platform.isAndroid) {
      final candidates = [
        Directory('/data/user/0/$androidPackageName/files/DartPad'),
        Directory('/data/data/$androidPackageName/files/DartPad'),
        Directory('/data/user/0/com.ferdlcx.dartpad/files/DartPad'),
        Directory('/data/data/com.ferdlcx.dartpad/files/DartPad'),
      ];
      for (final dir in candidates) {
        try {
          dir.createSync(recursive: true);
          return DartPadConfigStore(dir);
        } catch (_) {}
      }
    }

    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return DartPadConfigStore(Directory('$home/.dartpad'));
  }

  Directory get profilesDir => Directory('${rootDirectory.path}/profiles');
  Directory get layoutsDir => Directory('${rootDirectory.path}/layouts');
  Directory get settingsDir => Directory('${rootDirectory.path}/settings');
  File get settingsFile => File('${settingsDir.path}/app_settings.json');

  static const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

  /// Initializes the folder structure and seeds default Xbox/PS profiles & landscape layout if missing.
  Future<void> ensureInitialized() async {
    try {
      await profilesDir.create(recursive: true);
      await layoutsDir.create(recursive: true);
      await settingsDir.create(recursive: true);

      final xboxFile = File('${profilesDir.path}/xbox_default.json');
      if (!await xboxFile.exists()) {
        await saveProfile(ControllerProfile.xboxDefault());
      }

      final psFile = File('${profilesDir.path}/ps_default.json');
      if (!await psFile.exists()) {
        await saveProfile(ControllerProfile.playstationDefault());
      }

      final landscapeFile =
          File('${layoutsDir.path}/xbox_authentic_v3.json');
      if (!await landscapeFile.exists()) {
        await saveLayout(ControllerLayout.defaultLandscape());
      }

      if (!await settingsFile.exists()) {
        await saveSettings(const DartPadAppSettings());
      }
    } catch (_) {}
  }

  Future<void> saveProfile(ControllerProfile profile) async {
    try {
      await profilesDir.create(recursive: true);
      final file = File('${profilesDir.path}/${profile.id}.json');
      await file.writeAsString(_prettyJson.convert(profile.toJson()));
    } catch (_) {}
  }

  Future<ControllerProfile> loadProfile(String profileId) async {
    try {
      final file = File('${profilesDir.path}/$profileId.json');
      if (!await file.exists()) {
        return profileId == 'ps_default'
            ? ControllerProfile.playstationDefault()
            : ControllerProfile.xboxDefault();
      }
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ControllerProfile.fromJson(map);
    } catch (_) {
      return ControllerProfile.xboxDefault();
    }
  }

  Future<void> saveLayout(ControllerLayout layout) async {
    try {
      await layoutsDir.create(recursive: true);
      final file = File('${layoutsDir.path}/${layout.id}.json');
      await file.writeAsString(_prettyJson.convert(layout.toJson()));
    } catch (_) {}
  }

  Future<ControllerLayout> loadLayout(String layoutId) async {
    try {
      final file = File('${layoutsDir.path}/$layoutId.json');
      if (!await file.exists()) {
        return ControllerLayout.defaultLandscape();
      }
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ControllerLayout.fromJson(map);
    } catch (_) {
      return ControllerLayout.defaultLandscape();
    }
  }

  Future<void> saveSettings(DartPadAppSettings settings) async {
    try {
      await settingsDir.create(recursive: true);
      await settingsFile.writeAsString(_prettyJson.convert(settings.toJson()));
    } catch (_) {}
  }

  Future<DartPadAppSettings> loadSettings() async {
    try {
      if (!await settingsFile.exists()) {
        return const DartPadAppSettings();
      }
      final map =
          jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
      return DartPadAppSettings.fromJson(map);
    } catch (_) {
      return const DartPadAppSettings();
    }
  }
}
