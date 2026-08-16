import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:test/test.dart';

/// Packages in insertion order: `old` was added first, `new` last. Timestamps
/// are spread far enough apart that ordering cannot hinge on clock resolution.
const _names = ['old_pkg', 'mid_pkg', 'new_pkg'];

Future<({ClubDatabase db, SqliteSearchIndex index})> _indexed() async {
  final db = await ClubDatabase.memory();
  addTearDown(db.close);
  final store = SqliteMetadataStore(db);
  await store.runMigrations();
  final index = SqliteSearchIndex(db);

  final base = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
  for (var i = 0; i < _names.length; i++) {
    final createdAt = base + i * Duration(days: 1).inMilliseconds;
    // Invert updated_at against created_at, so a test that passes for the
    // wrong reason (reading updated_at while claiming to read created_at)
    // fails instead of coincidentally agreeing.
    final updatedAt = base - i * Duration(days: 1).inMilliseconds;
    await db.execute(
      '''INSERT INTO packages (name, likes_count, created_at, updated_at)
         VALUES (?, 0, ?, ?)''',
      [_names[i], createdAt, updatedAt],
    );
    await index.indexPackage(
      IndexDocument(
        package: _names[i],
        description: 'a shared searchable description',
        // The FTS row carries no timestamps (ordering joins back to
        // `packages`), so these are deliberately left at a constant: if a
        // future index started ordering off the document instead of the
        // table, these tests would fail rather than quietly still pass.
        publishedAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
  }
  return (db: db, index: index);
}

Future<List<String>> _order(
  SqliteSearchIndex index,
  SearchOrder order, {
  String? query,
}) async {
  final result = await index.search(
    SearchQuery(query: query, order: order),
    scope: VisibilityScope.trustedInternal,
  );
  return result.hits.map((h) => h.package).toList();
}

void main() {
  group('SearchOrder.created', () {
    // Regression: this ordered ASC, so a freshly published package landed on
    // the last page of "Recently Added" and only ever showed up under
    // "Recently Updated".
    test('browse lists newest first', () async {
      final (:index, db: _) = await _indexed();

      expect(
        await _order(index, SearchOrder.created),
        ['new_pkg', 'mid_pkg', 'old_pkg'],
      );
    });

    test('search lists newest first', () async {
      final (:index, db: _) = await _indexed();

      expect(
        await _order(index, SearchOrder.created, query: 'searchable'),
        ['new_pkg', 'mid_pkg', 'old_pkg'],
      );
    });
  });

  group('SearchOrder.updated', () {
    test('browse lists most recently updated first', () async {
      final (:index, db: _) = await _indexed();

      expect(
        await _order(index, SearchOrder.updated),
        ['old_pkg', 'mid_pkg', 'new_pkg'],
      );
    });

    test('search lists most recently updated first', () async {
      final (:index, db: _) = await _indexed();

      expect(
        await _order(index, SearchOrder.updated, query: 'searchable'),
        ['old_pkg', 'mid_pkg', 'new_pkg'],
      );
    });
  });
}
