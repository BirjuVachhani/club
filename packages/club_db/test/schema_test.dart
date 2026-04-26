import 'package:club_db/club_db.dart';
import 'package:club_db/src/sql/schema.dart' as sql;
import 'package:test/test.dart';

void main() {
  group('schemaVersion / migrations state', () {
    test('migrations chain terminates at schemaVersion', () {
      expect(migrations, isNotEmpty);
      expect(migrations.last.toVersion, schemaVersion);
    });

    test('canonical schema contains no ALTER / DROP / UPDATE statements', () {
      // Pre-release policy: schema.dart folds every change into fresh
      // CREATE statements. Migrations live in the versioned chain, not
      // in the canonical schema list. Enforce the separation here.
      final statements = sql.schema.map((stmt) => stmt.trim().toUpperCase());
      expect(
        statements.where(
          (stmt) =>
              stmt.startsWith('ALTER TABLE') ||
              stmt.startsWith('DROP TABLE') ||
              stmt.startsWith('DROP INDEX') ||
              stmt.startsWith('UPDATE '),
        ),
        isEmpty,
        reason:
            'schema.dart must stay canonical — migrations go in '
            '`migrations` in migrations.dart',
      );
    });

    test(
      'module-level migrations list passes validateMigrations',
      () => validateMigrations(migrations, schemaVersion),
    );
  });

  group('validateMigrations', () {
    test('accepts empty list when schemaVersion is 0 (pre-release)', () {
      validateMigrations(const [], 0);
    });

    test('rejects negative schemaVersion', () {
      expect(() => validateMigrations(const [], -1), throwsStateError);
      expect(() => validateMigrations(const [], -5), throwsStateError);
    });

    test('rejects empty list when schemaVersion > 0', () {
      expect(() => validateMigrations(const [], 1), throwsStateError);
      expect(() => validateMigrations(const [], 2), throwsStateError);
    });

    test('accepts a well-formed single-step chain 0 → 1', () {
      validateMigrations(const [
        SchemaMigration(
          fromVersion: 0,
          toVersion: 1,
          statements: ['ALTER TABLE users ADD COLUMN nickname TEXT'],
        ),
      ], 1);
    });

    test('accepts a well-formed multi-step chain', () {
      validateMigrations(const [
        SchemaMigration(
          fromVersion: 0,
          toVersion: 1,
          statements: ['ALTER TABLE users ADD COLUMN a TEXT'],
        ),
        SchemaMigration(
          fromVersion: 1,
          toVersion: 2,
          statements: ['ALTER TABLE users ADD COLUMN b TEXT'],
        ),
      ], 2);
    });

    test('rejects a migration with no statements', () {
      expect(
        () => validateMigrations(const [
          SchemaMigration(fromVersion: 0, toVersion: 1, statements: []),
        ], 1),
        throwsStateError,
      );
    });

    test('rejects toVersion <= fromVersion', () {
      expect(
        () => validateMigrations(const [
          SchemaMigration(
            fromVersion: 1,
            toVersion: 1,
            statements: ['SELECT 1'],
          ),
        ], 1),
        throwsStateError,
      );
      expect(
        () => validateMigrations(const [
          SchemaMigration(
            fromVersion: 3,
            toVersion: 2,
            statements: ['SELECT 1'],
          ),
        ], 3),
        throwsStateError,
      );
    });

    test('rejects a gap in the chain', () {
      expect(
        () => validateMigrations(const [
          SchemaMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: ['SELECT 1'],
          ),
          // Missing 1 → 2
          SchemaMigration(
            fromVersion: 2,
            toVersion: 3,
            statements: ['SELECT 1'],
          ),
        ], 3),
        throwsStateError,
      );
    });

    test('rejects duplicate fromVersion', () {
      expect(
        () => validateMigrations(const [
          SchemaMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: ['SELECT 1'],
          ),
          SchemaMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: ['SELECT 2'],
          ),
        ], 1),
        throwsStateError,
      );
    });

    test("rejects chain that doesn't terminate at the target", () {
      expect(
        () => validateMigrations(const [
          SchemaMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: ['SELECT 1'],
          ),
        ], 2),
        throwsStateError,
      );
    });
  });

  group('runMigrations — fresh install', () {
    test('creates the current schema and stamps at schemaVersion', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);

      await db.runMigrations();

      // Spot-check every column that had been added via a historical
      // ALTER TABLE and is now folded into the canonical CREATE — both
      // the pre-release changes and the v0 → v1 location columns should
      // be present on a fresh install without the migration running.
      await db.select('SELECT avatar, has_avatar FROM users LIMIT 1');
      await db.select('SELECT verified FROM publishers LIMIT 1');
      await db.select(
        'SELECT bin_executables, screenshots FROM package_versions LIMIT 1',
      );
      await db.select('SELECT topics FROM package_fts LIMIT 1');
      await db.select(
        'SELECT client_city, client_region, client_country, '
        'client_country_code FROM api_tokens LIMIT 1',
      );

      final schemaRows = await db.select(
        "SELECT value FROM club_schema WHERE key = 'schema_version'",
      );
      expect(schemaRows.single.read<int>('value'), schemaVersion);

      final versionRows = await db.select('PRAGMA user_version');
      expect(versionRows.single.read<int>('user_version'), schemaVersion);
    });

    test('is idempotent across repeat calls', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);

      await db.runMigrations();
      final firstSchema = await _dumpSchema(db);

      // Second run should be a no-op; no errors, no schema change.
      await db.runMigrations();
      final secondSchema = await _dumpSchema(db);

      expect(secondSchema, firstSchema);

      final versionRows = await db.select(
        "SELECT value FROM club_schema WHERE key = 'schema_version'",
      );
      expect(versionRows.single.read<int>('value'), schemaVersion);
    });
  });

  group('runMigrations — upgrade path', () {
    test('refuses to downgrade a DB whose version exceeds target', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);

      await db.runMigrations();

      // Forge a DB that claims to be at version 99 — simulates running
      // an older server binary against a DB migrated by a newer build.
      await db.execute(
        "UPDATE club_schema SET value = 99 WHERE key = 'schema_version'",
      );

      expect(db.runMigrations(), throwsStateError);
    });

    test('applies a synthetic v0 → v1 migration end-to-end', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);

      // Initialise at the current schemaVersion, then force-rewind to v0
      // to simulate a DB that was provisioned under the pre-release shape
      // and needs the v0 → v1 migration to run.
      await db.runMigrations();
      await db.execute(
        "UPDATE club_schema SET value = 0 WHERE key = 'schema_version'",
      );

      // Inject a synthetic migration chain and re-run — this exercises
      // the loop that real production DBs hit when an older DB boots
      // against a newer binary.
      await runMigrations(
        db,
        migrationsOverride: const [
          SchemaMigration(
            fromVersion: 0,
            toVersion: 1,
            statements: [
              'CREATE TABLE test_scratch (id TEXT PRIMARY KEY)',
              "INSERT INTO test_scratch (id) VALUES ('sentinel')",
            ],
          ),
        ],
        targetVersionOverride: 1,
      );

      // Version bumped
      final schemaRows = await db.select(
        "SELECT value FROM club_schema WHERE key = 'schema_version'",
      );
      expect(schemaRows.single.read<int>('value'), 1);

      final versionRows = await db.select('PRAGMA user_version');
      expect(versionRows.single.read<int>('user_version'), 1);

      // Migration statements actually ran
      final scratch = await db.select('SELECT id FROM test_scratch');
      expect(scratch.single.read<String>('id'), 'sentinel');
    });

    test(
      'chains multiple synthetic migrations in a single call',
      () async {
        final db = await ClubDatabase.memory();
        addTearDown(db.close);

        await db.runMigrations();
        await db.execute(
          "UPDATE club_schema SET value = 0 WHERE key = 'schema_version'",
        );

        await runMigrations(
          db,
          migrationsOverride: const [
            SchemaMigration(
              fromVersion: 0,
              toVersion: 1,
              statements: ['CREATE TABLE step_a (id INTEGER)'],
            ),
            SchemaMigration(
              fromVersion: 1,
              toVersion: 2,
              statements: ['CREATE TABLE step_b (id INTEGER)'],
            ),
          ],
          targetVersionOverride: 2,
        );

        final rows = await db.select(
          "SELECT value FROM club_schema WHERE key = 'schema_version'",
        );
        expect(rows.single.read<int>('value'), 2);

        // Both tables exist.
        await db.select('SELECT id FROM step_a LIMIT 1');
        await db.select('SELECT id FROM step_b LIMIT 1');
      },
    );

    test(
      'rolls back atomically when a migration statement fails',
      () async {
        final db = await ClubDatabase.memory();
        addTearDown(db.close);

        await db.runMigrations();
        await db.execute(
          "UPDATE club_schema SET value = 0 WHERE key = 'schema_version'",
        );

        final call = runMigrations(
          db,
          migrationsOverride: const [
            SchemaMigration(
              fromVersion: 0,
              toVersion: 1,
              statements: [
                'CREATE TABLE survived (id INTEGER)',
                // Deliberately broken SQL.
                'SYNTAX ERROR HERE',
              ],
            ),
          ],
          targetVersionOverride: 1,
        );

        await expectLater(call, throwsA(anything));

        // Version must still be 0: the failed migration rolled back.
        final rows = await db.select(
          "SELECT value FROM club_schema WHERE key = 'schema_version'",
        );
        expect(rows.single.read<int>('value'), 0);

        // The first statement must not have persisted either — atomicity
        // holds across the whole migration step.
        final tables = await db.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND "
          "name = 'survived'",
        );
        expect(tables, isEmpty);
      },
    );

    test(
      'rejects a malformed migrations override at the boundary',
      () async {
        final db = await ClubDatabase.memory();
        addTearDown(db.close);

        await db.runMigrations();

        // Gap in the chain — validateMigrations should reject before any
        // SQL runs.
        expect(
          () => runMigrations(
            db,
            migrationsOverride: const [
              SchemaMigration(
                fromVersion: 0,
                toVersion: 1,
                statements: ['SELECT 1'],
              ),
              SchemaMigration(
                fromVersion: 2, // gap
                toVersion: 3,
                statements: ['SELECT 1'],
              ),
            ],
            targetVersionOverride: 3,
          ),
          throwsStateError,
        );

        // Version unchanged — the DB is still at whatever the initial
        // `runMigrations` stamped it at (i.e. the current schemaVersion).
        final rows = await db.select(
          "SELECT value FROM club_schema WHERE key = 'schema_version'",
        );
        expect(rows.single.read<int>('value'), schemaVersion);
      },
    );
  });
}

/// Canonical-order dump of user-owned tables + indexes so two schemas
/// can be compared. Skips SQLite-internal rows (`sqlite_*` tables and
/// auto-generated FTS5 shadow tables) to avoid false diffs.
Future<String> _dumpSchema(ClubDatabase db) async {
  final rows = await db.select('''
    SELECT type, name, tbl_name, sql
    FROM sqlite_master
    WHERE name NOT LIKE 'sqlite_%'
    ORDER BY type, name
  ''');
  final buf = StringBuffer();
  for (final row in rows) {
    final sql = row.readNullable<String>('sql');
    buf.writeln('${row.read<String>('type')} ${row.read<String>('name')}');
    if (sql != null) buf.writeln(sql);
    buf.writeln();
  }
  return buf.toString();
}
