import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:logging/logging.dart';

import 'migrations.dart' as mig;

final _log = Logger('ClubDatabase');

/// Wraps a drift [GeneratedDatabase] providing raw SQL access to the club
/// SQLite database.
class ClubDatabase {
  ClubDatabase._(this._db);

  final _RawDatabase _db;

  /// Opens (or creates) the SQLite database at [path].
  ///
  /// If [path] is `null` an in-memory database is created (useful for tests).
  static Future<ClubDatabase> open({String? path}) async {
    final QueryExecutor executor;
    if (path != null) {
      final file = File(path);
      // Ensure parent directory exists.
      await file.parent.create(recursive: true);
      executor = NativeDatabase.createInBackground(file);
    } else {
      executor = NativeDatabase.memory();
    }

    final db = _RawDatabase(executor);
    final instance = ClubDatabase._(db);
    await instance._setPragmas();
    return instance;
  }

  /// Opens an in-memory database -- convenience for tests.
  static Future<ClubDatabase> memory() => open();

  Future<void> _setPragmas() async {
    await _db.customStatement('PRAGMA journal_mode = WAL');
    await _db.customStatement('PRAGMA foreign_keys = ON');
    await _db.customStatement('PRAGMA busy_timeout = 5000');
  }

  /// Creates a fresh schema or applies pending migrations.
  Future<void> runMigrations() => mig.runMigrations(this);

  /// Executes a raw SQL statement (INSERT / UPDATE / DELETE / DDL).
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await _db.customStatement(sql, args);
  }

  /// Executes a raw SELECT and returns the result rows.
  Future<List<QueryRow>> select(
    String sql, [
    List<Object?> args = const [],
  ]) {
    return _db.customSelect(sql, variables: _variables(args)).get();
  }

  /// Wraps [action] in a SQLite transaction.
  Future<T> transaction<T>(Future<T> Function() action) {
    return _db.transaction(action);
  }

  /// Closes the database.
  Future<void> close() async {
    _log.info('Closing database');
    await _db.close();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static List<Variable<Object>> _variables(List<Object?> args) {
    return args.map((a) => Variable<Object>(a)).toList();
  }
}

/// Minimal [GeneratedDatabase] subclass that gives us access to drift's
/// query engine without needing generated table classes.
///
/// club tracks its real schema version in the `club_schema` table and
/// in `mig.schemaVersion` — drift's migration machinery is bypassed
/// (see [migration] below), but we still need to align drift's view of
/// the version with `PRAGMA user_version` because drift reads/writes
/// that pragma itself on every open. If drift's [schemaVersion] gets
/// out of sync with the value `runMigrations` mirrors to
/// `PRAGMA user_version`, drift's default `onUpgrade` (which throws
/// "you've bumped the schema version…") fires before we can run
/// anything. So we forward to `mig.schemaVersion`, clamped to drift's
/// minimum of `1` (drift uses `0` internally to mean
/// "uninitialised").
class _RawDatabase extends GeneratedDatabase {
  _RawDatabase(super.executor);

  @override
  int get schemaVersion =>
      mig.schemaVersion < 1 ? 1 : mig.schemaVersion;

  /// All hooks are no-ops — club's [mig.runMigrations] is the single
  /// source of truth and runs after [open] returns. Without an
  /// explicit override here drift would install its default
  /// `onUpgrade` which throws on any version mismatch (including
  /// downgrades), wedging the server on every boot after the first
  /// schema bump. `onCreate` is also a no-op: `allSchemaEntities` is
  /// empty so there are no tables for drift to create either way.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {},
    onUpgrade: (m, from, to) async {},
  );

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities => const [];
}
