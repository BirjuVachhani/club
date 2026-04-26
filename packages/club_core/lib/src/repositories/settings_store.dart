import '../models/sdk_install.dart';

/// Abstract interface for server settings and SDK install management.
///
/// Implementations: SqliteSettingsStore.
abstract interface class SettingsStore {
  // ── Key-value settings ─────────────────────────────────────

  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
  Future<void> deleteSetting(String key);

  // ── Typed scoring settings ─────────────────────────────────

  Future<bool> getScoringEnabled();
  Future<void> setScoringEnabled(bool enabled);
  Future<String?> getDefaultSdkVersion();
  Future<void> setDefaultSdkVersion(String? version);

  // ── SDK installs ───────────────────────────────────────────

  Future<SdkInstall?> lookupSdkInstall(String id);
  Future<SdkInstall?> lookupSdkInstallByVersion(
    String version,
    String channel,
  );
  Future<List<SdkInstall>> listSdkInstalls();
  Future<SdkInstall> createSdkInstall(SdkInstallCompanion companion);
  Future<void> updateSdkInstallStatus(
    String id, {
    required SdkInstallStatus status,
    String? errorMessage,
    String? dartVersion,
    int? sizeBytes,
    DateTime? installedAt,
  });
  Future<void> deleteSdkInstall(String id);
  Future<void> setDefaultSdkInstall(String id);
  Future<List<SdkInstall>> listIncompleteInstalls();
}
