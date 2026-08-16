import 'package:club_db/club_db.dart';
import 'package:club_db/src/sql/schema.dart' as sql;
import 'package:test/test.dart';

/// The v2 → v3 migration and the canonical `schema.dart` must describe the
/// same database. `schema_test.dart` already forbids ALTER/DROP inside the
/// canonical list, which stops one half of the mistake; these tests close
/// the other half by checking that everything the migration creates also
/// exists on a fresh install, and vice versa.
///
/// Getting this wrong is silent: a fresh install and an upgraded install
/// diverge, and only one of them fails, usually in production.
void main() {
  final v3 = migrations.singleWhere((m) => m.toVersion == 3);
  final canonical = sql.schema.join('\n');

  group('v2 → v3 migration', () {
    test('every ADD COLUMN also exists in the canonical CREATE', () {
      final addColumn = RegExp(
        r'ALTER TABLE (\w+) ADD COLUMN (\w+)',
        caseSensitive: false,
      );

      final added = v3.statements
          .map(addColumn.firstMatch)
          .nonNulls
          .map((m) => (table: m.group(1)!, column: m.group(2)!))
          .toList();

      expect(
        added.map((e) => '${e.table}.${e.column}'),
        containsAll([
          'packages.visibility',
          'packages.visibility_changed_at',
          'packages.visibility_changed_by',
          'package_versions.public_resolvable',
        ]),
        reason: 'the visibility columns are the point of this migration',
      );

      for (final entry in added) {
        expect(
          canonical,
          contains(entry.column),
          reason:
              '${entry.table}.${entry.column} is added by the migration but '
              'is missing from schema.dart, so a fresh install would not '
              'have it',
        );
      }
    });

    test('every CREATE TABLE / INDEX also exists in the canonical schema', () {
      final create = RegExp(
        r'CREATE (?:TABLE|INDEX)(?: IF NOT EXISTS)? (\w+)',
        caseSensitive: false,
      );

      final created = v3.statements
          .map(create.firstMatch)
          .nonNulls
          .map((m) => m.group(1)!)
          .toList();

      expect(
        created,
        containsAll([
          'package_version_dependencies',
          'idx_packages_visibility',
          'idx_pvd_dep_name',
        ]),
      );

      for (final name in created) {
        expect(
          canonical,
          contains(name),
          reason:
              '$name is created by the migration but is missing from '
              'schema.dart',
        );
      }
    });

    test('a fresh install has every object the migration would create',
        () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);
      await db.runMigrations();

      // Selecting a column that does not exist throws, so these double as
      // existence assertions.
      await db.select(
        'SELECT visibility, visibility_changed_at, visibility_changed_by '
        'FROM packages LIMIT 1',
      );
      await db.select(
        'SELECT public_resolvable FROM package_versions LIMIT 1',
      );
      await db.select(
        'SELECT package_name, version, dep_name, kind, source, '
        'hosted_origin, is_local, is_ambiguous, constraint_text '
        'FROM package_version_dependencies LIMIT 1',
      );

      final indexes = await db.select(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      final names = indexes.map((r) => r.read<String>('name')).toSet();
      expect(names, containsAll(['idx_packages_visibility', 'idx_pvd_dep_name',
          'idx_pvd_package']));
    });
  });

  group('visibility defaults', () {
    /// The whole upgrade must be a behavioural no-op. A package that
    /// existed before this migration was reachable only with credentials,
    /// and it must stay that way until someone deliberately flips it.
    test('packages default to private and versions to not-resolvable',
        () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);
      await db.runMigrations();

      await db.execute(
        'INSERT INTO packages (name, created_at, updated_at) '
        'VALUES (?, ?, ?)',
        ['legacy_pkg', 0, 0],
      );
      await db.execute(
        'INSERT INTO package_versions '
        '(package_name, version, pubspec_json, archive_size_bytes, '
        ' archive_sha256, published_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['legacy_pkg', '1.0.0', '{}', 0, 'abc', 0],
      );

      final pkg = await db.select(
        'SELECT visibility FROM packages WHERE name = ?',
        ['legacy_pkg'],
      );
      expect(pkg.single.read<String>('visibility'), 'private');

      final version = await db.select(
        'SELECT public_resolvable FROM package_versions WHERE package_name = ?',
        ['legacy_pkg'],
      );
      expect(version.single.read<int>('public_resolvable'), 0);
    });

    test('a fresh install rejects an out-of-enum visibility', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);
      await db.runMigrations();

      await expectLater(
        db.execute(
          'INSERT INTO packages (name, visibility, created_at, updated_at) '
          'VALUES (?, ?, ?, ?)',
          ['bad_pkg', 'internet', 0, 0],
        ),
        throwsA(anything),
        reason: 'the CHECK constraint should reject unknown states on a '
            'fresh install (a migrated DB relies on PackageVisibility in '
            'Dart instead, since ALTER TABLE cannot add a CHECK)',
      );
    });

    test('dependency rows cascade away with their version', () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);
      await db.runMigrations();

      await db.execute(
        'INSERT INTO packages (name, created_at, updated_at) VALUES (?, ?, ?)',
        ['app', 0, 0],
      );
      await db.execute(
        'INSERT INTO package_versions '
        '(package_name, version, pubspec_json, archive_size_bytes, '
        ' archive_sha256, published_at) VALUES (?, ?, ?, ?, ?, ?)',
        ['app', '1.0.0', '{}', 0, 'abc', 0],
      );
      await db.execute(
        'INSERT INTO package_version_dependencies '
        '(package_name, version, dep_name, kind, source, is_local) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['app', '1.0.0', 'core_ui', 'direct', 'hosted', 1],
      );

      await db.execute(
        'DELETE FROM package_versions WHERE package_name = ? AND version = ?',
        ['app', '1.0.0'],
      );

      final rows = await db.select(
        'SELECT dep_name FROM package_version_dependencies',
      );
      expect(rows, isEmpty, reason: 'stale edges would corrupt the closure');
    });
  });
}
