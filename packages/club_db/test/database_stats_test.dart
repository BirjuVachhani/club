import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

Future<({SqliteMetadataStore store, ClubDatabase db})> _store() async {
  final db = await ClubDatabase.memory();
  addTearDown(db.close);
  final store = SqliteMetadataStore(db);
  await store.runMigrations();
  return (store: store, db: db);
}

/// Insert [count] packages so at least one table has enough content to be
/// countable and to show up in the size breakdown.
Future<void> _seedPackages(ClubDatabase db, int count) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i < count; i++) {
    await db.execute(
      '''INSERT INTO packages (name, likes_count, created_at, updated_at)
         VALUES (?, 0, ?, ?)''',
      ['pkg_$i', now, now],
    );
  }
}

void main() {
  group('databaseStats', () {
    test('reports page-derived sizes', () async {
      final (:store, :db) = await _store();

      final stats = await store.databaseStats();

      expect(stats.totalBytes, greaterThan(0));
      // page_count * page_size, so always a whole number of pages.
      expect(stats.totalBytes % 4096, 0);
      // Freshly migrated, nothing deleted yet, so nothing to reclaim.
      expect(stats.reclaimableBytes, 0);
    });

    test('lists relations largest first, capped at topTables', () async {
      final (:store, :db) = await _store();
      await _seedPackages(db, 50);

      final stats = await store.databaseStats(topTables: 5);

      expect(stats.tables, isNotEmpty);
      expect(stats.tables.length, lessThanOrEqualTo(5));
      expect(
        stats.tables.map((t) => t.bytes).toList(),
        orderedEquals(
          [...stats.tables.map((t) => t.bytes)]..sort((a, b) => b.compareTo(a)),
        ),
      );
    });

    test('counts rows for tables and leaves indexes uncounted', () async {
      final (:store, :db) = await _store();
      await _seedPackages(db, 50);

      // Ask wide enough to cover the whole catalog, so both a table and an
      // index are guaranteed to be in the result.
      final stats = await store.databaseStats(topTables: 200);
      final byName = {for (final t in stats.tables) t.name: t};

      final packages = byName['packages'];
      expect(packages, isNotNull, reason: 'packages table should be listed');
      expect(packages!.isIndex, isFalse);
      expect(packages.rows, 50);

      final index = stats.tables.firstWhere((t) => t.isIndex);
      expect(
        index.rows,
        isNull,
        reason: 'indexes have no row count to report',
      );
      expect(index.bytes, greaterThan(0));
    });

    test('reports reclaimable space after a delete', () async {
      final (:store, :db) = await _store();
      // Enough rows that deleting them frees whole pages onto the freelist.
      await _seedPackages(db, 500);
      await db.execute('DELETE FROM packages');

      final stats = await store.databaseStats();

      expect(stats.reclaimableBytes, greaterThan(0));
    });
  });
}
