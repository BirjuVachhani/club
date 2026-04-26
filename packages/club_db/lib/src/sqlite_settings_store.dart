import 'package:drift/drift.dart';
import 'package:club_core/club_core.dart';

import 'database.dart';

/// SQLite implementation of [SettingsStore] using raw SQL via drift.
class SqliteSettingsStore implements SettingsStore {
  SqliteSettingsStore(this._db);

  final ClubDatabase _db;

  // ── Key-value settings ─────────────────────────────────────────────────────

  @override
  Future<String?> getSetting(String key) async {
    final rows = await _db.select(
      'SELECT value FROM server_settings WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return rows.first.read<String>('value');
  }

  @override
  Future<void> setSetting(String key, String value) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO server_settings (key, value, updated_at)
         VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at''',
      [key, value, now],
    );
  }

  @override
  Future<void> deleteSetting(String key) async {
    await _db.execute('DELETE FROM server_settings WHERE key = ?', [key]);
  }

  // ── Typed scoring settings ─────────────────────────────────────────────────

  static const _scoringEnabledKey = 'scoring_enabled';
  static const _defaultSdkVersionKey = 'default_sdk_version';

  @override
  Future<bool> getScoringEnabled() async {
    final v = await getSetting(_scoringEnabledKey);
    return v == 'true';
  }

  @override
  Future<void> setScoringEnabled(bool enabled) =>
      setSetting(_scoringEnabledKey, enabled.toString());

  @override
  Future<String?> getDefaultSdkVersion() => getSetting(_defaultSdkVersionKey);

  @override
  Future<void> setDefaultSdkVersion(String? version) async {
    if (version == null || version.isEmpty) {
      await deleteSetting(_defaultSdkVersionKey);
    } else {
      await setSetting(_defaultSdkVersionKey, version);
    }
  }

  // ── SDK installs ───────────────────────────────────────────────────────────

  @override
  Future<SdkInstall?> lookupSdkInstall(String id) async {
    final rows = await _db.select(
      'SELECT * FROM sdk_installs WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToSdkInstall(rows.first);
  }

  @override
  Future<SdkInstall?> lookupSdkInstallByVersion(
    String version,
    String channel,
  ) async {
    final rows = await _db.select(
      'SELECT * FROM sdk_installs WHERE version = ? AND channel = ?',
      [version, channel],
    );
    if (rows.isEmpty) return null;
    return _rowToSdkInstall(rows.first);
  }

  @override
  Future<List<SdkInstall>> listSdkInstalls() async {
    final rows = await _db.select(
      'SELECT * FROM sdk_installs ORDER BY created_at DESC',
    );
    return rows.map(_rowToSdkInstall).toList();
  }

  @override
  Future<SdkInstall> createSdkInstall(SdkInstallCompanion companion) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.execute(
      '''INSERT INTO sdk_installs
         (id, channel, version, dart_version, install_path,
          size_bytes, status, error_message, is_default, installed_at,
          created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        companion.id,
        companion.channel,
        companion.version,
        companion.dartVersion,
        companion.installPath,
        companion.sizeBytes,
        companion.status.name,
        companion.errorMessage,
        companion.isDefault ? 1 : 0,
        companion.installedAt?.millisecondsSinceEpoch,
        now,
        now,
      ],
    );
    return (await lookupSdkInstall(companion.id))!;
  }

  @override
  Future<void> updateSdkInstallStatus(
    String id, {
    required SdkInstallStatus status,
    String? errorMessage,
    String? dartVersion,
    int? sizeBytes,
    DateTime? installedAt,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final sets = <String>['status = ?', 'updated_at = ?'];
    final args = <Object?>[status.name, now];

    if (errorMessage != null) {
      sets.add('error_message = ?');
      args.add(errorMessage);
    }
    if (dartVersion != null) {
      sets.add('dart_version = ?');
      args.add(dartVersion);
    }
    if (sizeBytes != null) {
      sets.add('size_bytes = ?');
      args.add(sizeBytes);
    }
    if (installedAt != null) {
      sets.add('installed_at = ?');
      args.add(installedAt.millisecondsSinceEpoch);
    }

    args.add(id);
    await _db.execute(
      'UPDATE sdk_installs SET ${sets.join(', ')} WHERE id = ?',
      args,
    );
  }

  @override
  Future<void> deleteSdkInstall(String id) async {
    await _db.execute('DELETE FROM sdk_installs WHERE id = ?', [id]);
  }

  @override
  Future<void> setDefaultSdkInstall(String id) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    // Clear any existing default.
    await _db.execute(
      'UPDATE sdk_installs SET is_default = 0, updated_at = ? WHERE is_default = 1',
      [now],
    );
    // Set the new default.
    await _db.execute(
      'UPDATE sdk_installs SET is_default = 1, updated_at = ? WHERE id = ?',
      [now, id],
    );
  }

  @override
  Future<List<SdkInstall>> listIncompleteInstalls() async {
    final rows = await _db.select(
      "SELECT * FROM sdk_installs WHERE status IN ('cloning', 'settingUp')",
    );
    return rows.map(_rowToSdkInstall).toList();
  }

  // ── Row mapping ────────────────────────────────────────────────────────────

  static SdkInstall _rowToSdkInstall(QueryRow row) {
    return SdkInstall(
      id: row.read<String>('id'),
      channel: row.read<String>('channel'),
      version: row.read<String>('version'),
      dartVersion: row.readNullable<String>('dart_version'),
      installPath: row.read<String>('install_path'),
      sizeBytes: row.readNullable<int>('size_bytes'),
      status: SdkInstallStatus.fromString(row.read<String>('status')),
      errorMessage: row.readNullable<String>('error_message'),
      isDefault: (row.read<int>('is_default')) != 0,
      installedAt: _nullableIntToDateTime(
        row.readNullable<int>('installed_at'),
      ),
      createdAt: _intToDateTime(row.read<int>('created_at')),
      updatedAt: _intToDateTime(row.read<int>('updated_at')),
    );
  }

  static DateTime _intToDateTime(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static DateTime? _nullableIntToDateTime(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}
