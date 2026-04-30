/// Status of a Flutter SDK installation.
enum SdkInstallStatus {
  /// Repository is being cloned.
  cloning,

  /// SDK is being set up (running `flutter --version` to fetch dependencies).
  settingUp,

  /// SDK is installed and ready for use.
  ready,

  /// Installation failed.
  failed
  ;

  static SdkInstallStatus fromString(String value) =>
      SdkInstallStatus.values.firstWhere(
        (e) => e.name == value,
        orElse: () => SdkInstallStatus.failed,
      );
}

/// A Flutter SDK version installed on the server for pana scoring.
class SdkInstall {
  const SdkInstall({
    required this.id,
    required this.channel,
    required this.version,
    this.dartVersion,
    required this.installPath,
    this.sizeBytes,
    required this.status,
    this.errorMessage,
    required this.isDefault,
    this.installedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String channel;
  final String version;
  final String? dartVersion;
  final String installPath;
  final int? sizeBytes;
  final SdkInstallStatus status;
  final String? errorMessage;
  final bool isDefault;
  final DateTime? installedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Write companion for creating/updating an SDK install row.
class SdkInstallCompanion {
  const SdkInstallCompanion({
    required this.id,
    required this.channel,
    required this.version,
    this.dartVersion,
    required this.installPath,
    this.sizeBytes,
    required this.status,
    this.errorMessage,
    this.isDefault = false,
    this.installedAt,
  });

  final String id;
  final String channel;
  final String version;
  final String? dartVersion;
  final String installPath;
  final int? sizeBytes;
  final SdkInstallStatus status;
  final String? errorMessage;
  final bool isDefault;
  final DateTime? installedAt;
}
