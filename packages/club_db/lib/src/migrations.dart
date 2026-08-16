import 'package:logging/logging.dart';

import 'database.dart';
import 'sql/schema.dart' as sql;

final _log = Logger('ClubMigrations');

/// Current SQLite schema version.
///
/// Bumped on every shipped schema change; each increment appends a
/// matching [SchemaMigration] to [migrations] covering that step.
/// Fresh installs apply the canonical [sql.schema] (kept in sync with
/// the latest layout) and are stamped here immediately; existing DBs
/// stamped at an older version step up through the migration chain.
///
/// `0` is the historical pre-release baseline: schema changes made
/// before the first release were folded directly into [sql.schema]
/// without versioned migrations. `1` is the first post-release
/// version, covering the `client_city` / `client_region` /
/// `client_country` / `client_country_code` columns on `api_tokens`
/// that capture the login-time geolocation snapshot. `2` adds the
/// `pana_tags` column to `package_scores` for caching pana's tag set
/// (`is:wasm-ready`, `is:plugin`, etc.) outside the full report blob.
/// `3` adds per-package visibility (`packages.visibility` and its audit
/// columns), the derived `package_versions.public_resolvable` flag, and
/// the `package_version_dependencies` edge index that the visibility
/// closure walks.
const int schemaVersion = 3;

/// A versioned SQL migration from [fromVersion] to [toVersion].
///
/// Migrations are applied inside the same transaction that re-reads and
/// writes the `club_schema` version row, so a crash or statement failure
/// rolls the DB back to [fromVersion] cleanly — either the whole step
/// completes or none of it does.
class SchemaMigration {
  const SchemaMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.statements,
  });

  final int fromVersion;
  final int toVersion;
  final List<String> statements;
}

/// Historical schema migrations.
///
/// Every released schema change appends exactly one entry here whose
/// `fromVersion` equals the previous entry's `toVersion` (or `0` for the
/// first entry), so migrations always form a gap-free chain terminating
/// at [schemaVersion]. [validateMigrations] enforces this at boot.
const List<SchemaMigration> migrations = [
  // v0 → v1: add login-time geolocation columns on api_tokens. Captured
  // once when the session is issued (via ipwho.is) and never updated,
  // mirroring the existing client_ip / user_agent snapshot semantics.
  // The canonical CREATE in schema.dart already includes these columns
  // so fresh installs skip straight to v1; this migration only runs on
  // DBs provisioned against the pre-release v0 shape.
  SchemaMigration(
    fromVersion: 0,
    toVersion: 1,
    statements: [
      'ALTER TABLE api_tokens ADD COLUMN client_city TEXT',
      'ALTER TABLE api_tokens ADD COLUMN client_region TEXT',
      'ALTER TABLE api_tokens ADD COLUMN client_country TEXT',
      'ALTER TABLE api_tokens ADD COLUMN client_country_code TEXT',
    ],
  ),
  // v1 → v2: cache pana's emitted tag set on the score row so `getScore`
  // can merge them with the publish-time tags without parsing the full
  // report JSON on every read. Stored as a JSON array of strings; null
  // until the next pana run repopulates it (operator triggers a rescore).
  SchemaMigration(
    fromVersion: 1,
    toVersion: 2,
    statements: [
      'ALTER TABLE package_scores ADD COLUMN pana_tags TEXT',
    ],
  ),
  // v2 → v3: per-package visibility plus the dependency edge index the
  // visibility closure walks.
  //
  // Every existing package lands on `'private'`, which is exactly the
  // behaviour it had before this column existed, so the upgrade is a
  // no-op until an operator turns the feature on and flips something.
  // Likewise `public_resolvable` defaults to 0: nothing is anonymously
  // listable until VisibilityService computes it.
  //
  // Two constraints that the canonical schema.dart carries are absent
  // here, because SQLite's `ALTER TABLE ADD COLUMN` accepts neither a
  // CHECK nor a REFERENCES clause:
  //   - `CHECK (visibility IN ('private','public'))`
  //   - `visibility_changed_by REFERENCES users(user_id)`
  // A migrated database therefore trusts Dart (`PackageVisibility`) to
  // keep the enum honest, while a fresh install gets both. Closing the
  // gap needs SQLite's 12-step table rebuild, which is not worth the
  // risk for a soft reference: `package_versions.publisher_id` is
  // already a soft reference for the same reason.
  SchemaMigration(
    fromVersion: 2,
    toVersion: 3,
    statements: [
      "ALTER TABLE packages ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private'",
      'ALTER TABLE packages ADD COLUMN visibility_changed_at INTEGER',
      'ALTER TABLE packages ADD COLUMN visibility_changed_by TEXT',
      'ALTER TABLE package_versions ADD COLUMN public_resolvable INTEGER NOT NULL DEFAULT 0',
      '''
      CREATE TABLE IF NOT EXISTS package_version_dependencies (
        package_name    TEXT NOT NULL,
        version         TEXT NOT NULL,
        dep_name        TEXT NOT NULL,
        kind            TEXT NOT NULL
                          CHECK (kind IN ('direct','dev','override')),
        source          TEXT NOT NULL
                          CHECK (source IN ('hosted','bare','sdk','path','git')),
        hosted_origin   TEXT,
        is_local        INTEGER NOT NULL DEFAULT 0,
        is_ambiguous    INTEGER NOT NULL DEFAULT 0,
        constraint_text TEXT,
        PRIMARY KEY (package_name, version, dep_name, kind),
        FOREIGN KEY (package_name, version)
          REFERENCES package_versions(package_name, version) ON DELETE CASCADE
      )
      ''',
      'CREATE INDEX IF NOT EXISTS idx_packages_visibility ON packages(visibility)',
      'CREATE INDEX IF NOT EXISTS idx_pvd_dep_name ON package_version_dependencies(dep_name, is_local)',
      'CREATE INDEX IF NOT EXISTS idx_pvd_package ON package_version_dependencies(package_name, version)',
    ],
  ),
];

/// Validate that [migrations] forms a well-formed chain terminating at
/// [target]. Throws [StateError] on any of these misconfigurations:
///
///   - `target < 1`
///   - an empty migration statements list
///   - a non-monotonic step (`toVersion <= fromVersion`)
///   - a gap in the chain (next `fromVersion != previous toVersion`)
///   - a duplicate `fromVersion`
///   - the chain's final `toVersion` doesn't match [target]
///
/// Called at the top of [runMigrations] so prod fails loud at boot instead
/// of during an upgrade window. Exposed so tests can also exercise it
/// directly with synthetic chains.
void validateMigrations(
  List<SchemaMigration> migrations,
  int target,
) {
  if (target < 0) {
    throw StateError('schemaVersion must be >= 0 (got $target).');
  }

  if (migrations.isEmpty) {
    if (target != 0) {
      throw StateError(
        'schemaVersion is $target but no migrations are declared. '
        'Add SchemaMigration entries covering 0 → $target, or reset '
        'schemaVersion to 0 while the project is pre-release.',
      );
    }
    return;
  }

  final seenFrom = <int>{};
  var expectedFrom = migrations.first.fromVersion;

  for (final m in migrations) {
    if (m.statements.isEmpty) {
      throw StateError(
        'SchemaMigration v${m.fromVersion} → v${m.toVersion} has no '
        'statements. A no-op schema change should not ship as a '
        'migration.',
      );
    }
    if (m.toVersion <= m.fromVersion) {
      throw StateError(
        'SchemaMigration toVersion (${m.toVersion}) must be strictly '
        'greater than fromVersion (${m.fromVersion}).',
      );
    }
    if (!seenFrom.add(m.fromVersion)) {
      throw StateError(
        'Duplicate SchemaMigration with fromVersion ${m.fromVersion}. '
        'Each version has exactly one successor.',
      );
    }
    if (m.fromVersion != expectedFrom) {
      throw StateError(
        'Migration chain gap: expected fromVersion $expectedFrom, got '
        '${m.fromVersion}. Entries in `migrations` must be listed in '
        'order with each fromVersion equal to the previous toVersion.',
      );
    }
    expectedFrom = m.toVersion;
  }

  final finalVersion = migrations.last.toVersion;
  if (finalVersion != target) {
    throw StateError(
      'Migration chain ends at version $finalVersion but schemaVersion '
      'is $target. Either append a migration terminating at $target or '
      'adjust schemaVersion to match the final migration.',
    );
  }
}

/// Creates a fresh schema or applies pending versioned migrations.
///
/// The whole operation runs under `BEGIN IMMEDIATE` so a second
/// concurrently-starting replica blocks until the first finishes instead
/// of both racing into the same `initialVersion == 0` branch. On success
/// the transaction commits; on any failure it rolls back and the version
/// row stays at its previous value.
///
/// [migrationsOverride] and [targetVersionOverride] exist only so tests
/// can exercise synthetic migration chains. Prod callers leave them
/// null; the module-level [migrations] and [schemaVersion] apply.
Future<void> runMigrations(
  ClubDatabase db, {
  List<SchemaMigration>? migrationsOverride,
  int? targetVersionOverride,
}) async {
  final activeMigrations = migrationsOverride ?? migrations;
  final target = targetVersionOverride ?? schemaVersion;

  // Fail loud at boot on a malformed chain rather than during the
  // upgrade window itself.
  validateMigrations(activeMigrations, target);

  // BEGIN IMMEDIATE acquires the write lock immediately instead of on the
  // first write, which closes a TOCTOU window when two replicas boot
  // concurrently against the same DB file. Without it both could read
  // `initialVersion == 0` in their own deferred transactions before
  // either writes.
  await db.execute('BEGIN IMMEDIATE');
  try {
    await _ensureVersionTable(db);
    final initialVersion = await _readSchemaVersion(db);

    // Null initialVersion = no row in `club_schema` yet (DB never booted
    // against this binary). Apply the canonical schema and stamp at
    // target. Keeping "uninitialised" distinct from "stamped at 0" is
    // what lets a later 0 → 1 migration actually run for databases
    // that were provisioned on a pre-release build — if we treated
    // both as 0, the v1 release would silently skip the upgrade.
    if (initialVersion == null) {
      await _applyStatements(db, sql.schema);
      await _setSchemaVersion(db, target);
      _log.fine('Initialized schema at version $target.');
      await db.execute('COMMIT');
      return;
    }

    if (initialVersion > target) {
      throw StateError(
        'Database schema version $initialVersion is newer than '
        'supported version $target. Refusing to run an older binary '
        'against a newer database.',
      );
    }

    if (initialVersion == target) {
      _log.fine('Schema already at version $target; no migration needed.');
      await db.execute('COMMIT');
      return;
    }

    var version = initialVersion;
    for (final migration in activeMigrations) {
      if (migration.fromVersion < version) continue;
      if (migration.fromVersion > version) break;
      await _applyStatements(db, migration.statements);
      version = migration.toVersion;
      await _setSchemaVersion(db, version);
      _log.info(
        'Migrated schema ${migration.fromVersion} → $version.',
      );
    }

    // Defensive: validateMigrations guarantees a complete chain from
    // version 1 to target, but initialVersion could be >1 (a DB
    // initialised on an older build). If no migration covered it, fail
    // clearly rather than committing a half-migrated DB.
    if (version != target) {
      throw StateError(
        'No migration path from schema version $initialVersion to '
        '$target. `migrations` must cover every version that any '
        'released build has persisted.',
      );
    }

    await db.execute('COMMIT');
  } catch (e) {
    // ROLLBACK can itself fail (e.g. if the connection was already
    // closed by a fatal error) — swallow that to preserve the original
    // exception for the caller.
    try {
      await db.execute('ROLLBACK');
    } catch (_) {}
    rethrow;
  }
}

Future<void> _applyStatements(
  ClubDatabase db,
  Iterable<String> statements,
) {
  return Future.forEach(statements, (stmt) async {
    final trimmed = stmt.trim();
    if (trimmed.isEmpty) return;
    await db.execute(trimmed);
  });
}

/// Returns the currently-stamped schema version, or `null` when the DB
/// has never been initialised (no row in `club_schema`). Returning null
/// for the "no row" case lets callers distinguish a fresh DB from one
/// that was explicitly stamped at version 0.
Future<int?> _readSchemaVersion(ClubDatabase db) async {
  final rows = await db.select(
    "SELECT value FROM club_schema WHERE key = 'schema_version'",
  );
  if (rows.isEmpty) return null;
  return rows.first.read<int>('value');
}

Future<void> _setSchemaVersion(ClubDatabase db, int version) async {
  await db.execute(
    '''
    INSERT INTO club_schema (key, value)
    VALUES ('schema_version', ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ''',
    [version],
  );
  // Mirror to PRAGMA user_version so `sqlite3 .schema` and external
  // backup tools see the same number as `club_schema.schema_version`.
  await db.execute('PRAGMA user_version = $version');
}

Future<void> _ensureVersionTable(ClubDatabase db) {
  return db.execute('''
    CREATE TABLE IF NOT EXISTS club_schema (
      key   TEXT PRIMARY KEY NOT NULL,
      value INTEGER NOT NULL
    )
  ''');
}
