import 'dart:convert';
import 'dart:io';

import 'controller_layout.dart';
import 'controller_profile.dart';

/// Application settings stored in `DartPad/settings/app_settings.json`.
class DartPadAppSettings {
  final int updateRateHz;
  final bool autoReconnect;
  final bool hapticFeedback;
  final bool landscapeLock;
  final bool keepScreenAwake;
  final String activeProfileId;
  final String activeLayoutId;
  final String? lastConnectedIp;
  final int lastConnectedPort;

  const DartPadAppSettings({
    this.updateRateHz = 120,
    this.autoReconnect = true,
    this.hapticFeedback = true,
    this.landscapeLock = true,
    this.keepScreenAwake = true,
    this.activeProfileId = 'xbox_default',
    this.activeLayoutId = 'landscape_default',
    this.lastConnectedIp,
    this.lastConnectedPort = 42100,
  });

  DartPadAppSettings copyWith({
    int? updateRateHz,
    bool? autoReconnect,
    bool? hapticFeedback,
    bool? landscapeLock,
    bool? keepScreenAwake,
    String? activeProfileId,
    String? activeLayoutId,
    String? lastConnectedIp,
    int? lastConnectedPort,
  }) {
    return DartPadAppSettings(
      updateRateHz: updateRateHz ?? this.updateRateHz,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      landscapeLock: landscapeLock ?? this.landscapeLock,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      activeProfileId: activeProfileId ?? this.activeProfileId,
      activeLayoutId: activeLayoutId ?? this.activeLayoutId,
      lastConnectedIp: lastConnectedIp ?? this.lastConnectedIp,
      lastConnectedPort: lastConnectedPort ?? this.lastConnectedPort,
    );
  }

  Map<String, dynamic> toJson() => {
        'updateRateHz': updateRateHz,
        'autoReconnect': autoReconnect,
        'hapticFeedback': hapticFeedback,
        'landscapeLock': landscapeLock,
        'keepScreenAwake': keepScreenAwake,
        'activeProfileId': activeProfileId,
        'activeLayoutId': activeLayoutId,
        if (lastConnectedIp != null) 'lastConnectedIp': lastConnectedIp,
        'lastConnectedPort': lastConnectedPort,
      };

  factory DartPadAppSettings.fromJson(Map<String, dynamic> json) {
    return DartPadAppSettings(
      updateRateHz: (json['updateRateHz'] as int?) ?? 120,
      autoReconnect: (json['autoReconnect'] as bool?) ?? true,
      hapticFeedback: (json['hapticFeedback'] as bool?) ?? true,
      landscapeLock: (json['landscapeLock'] as bool?) ?? true,
      keepScreenAwake: (json['keepScreenAwake'] as bool?) ?? true,
      activeProfileId: (json['activeProfileId'] as String?) ?? 'xbox_default',
      activeLayoutId: (json['activeLayoutId'] as String?) ?? 'landscape_default',
      lastConnectedIp: json['lastConnectedIp'] as String?,
      lastConnectedPort: (json['lastConnectedPort'] as int?) ?? 42100,
    );
  }
}

/// Manages local JSON configuration files inside the `DartPad/` folder structure:
/// ```text
/// DartPad/
/// ├── profiles/
/// │   ├── xbox_default.json
/// │   ├── ps_default.json
/// │   └── custom_profile.json
/// ├── layouts/
/// │   ├── landscape_default.json
/// │   └── custom_layout.json
/// └── settings/
///     └── app_settings.json
/// ```
class DartPadConfigStore {
  final Directory rootDirectory;

  DartPadConfigStore(this.rootDirectory);

  Directory get profilesDir => Directory('${rootDirectory.path}/profiles');
  Directory get layoutsDir => Directory('${rootDirectory.path}/layouts');
  Directory get settingsDir => Directory('${rootDirectory.path}/settings');
  File get settingsFile => File('${settingsDir.path}/app_settings.json');

  static const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

  /// Initializes the folder structure and seeds default Xbox/PS profiles & landscape layout if missing.
  Future<void> ensureInitialized() async {
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

    final landscapeFile = File('${layoutsDir.path}/landscape_default.json');
    if (!await landscapeFile.exists()) {
      await saveLayout(ControllerLayout.defaultLandscape());
    }

    if (!await settingsFile.exists()) {
      await saveSettings(const DartPadAppSettings());
    }
  }

  Future<void> saveProfile(ControllerProfile profile) async {
    await profilesDir.create(recursive: true);
    final file = File('${profilesDir.path}/${profile.id}.json');
    await file.writeAsString(_prettyJson.convert(profile.toJson()));
  }

  Future<ControllerProfile> loadProfile(String profileId) async {
    final file = File('${profilesDir.path}/$profileId.json');
    if (!await file.exists()) {
      return profileId == 'ps_default'
          ? ControllerProfile.playstationDefault()
          : ControllerProfile.xboxDefault();
    }
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return ControllerProfile.fromJson(map);
  }

  Future<void> saveLayout(ControllerLayout layout) async {
    await layoutsDir.create(recursive: true);
    final file = File('${layoutsDir.path}/${layout.id}.json');
    await file.writeAsString(_prettyJson.convert(layout.toJson()));
  }

  Future<ControllerLayout> loadLayout(String layoutId) async {
    final file = File('${layoutsDir.path}/$layoutId.json');
    if (!await file.exists()) {
      return ControllerLayout.defaultLandscape();
    }
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return ControllerLayout.fromJson(map);
  }

  Future<void> saveSettings(DartPadAppSettings settings) async {
    await settingsDir.create(recursive: true);
    await settingsFile.writeAsString(_prettyJson.convert(settings.toJson()));
  }

  Future<DartPadAppSettings> loadSettings() async {
    if (!await settingsFile.exists()) {
      return const DartPadAppSettings();
    }
    final map =
        jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
    return DartPadAppSettings.fromJson(map);
  }
}
