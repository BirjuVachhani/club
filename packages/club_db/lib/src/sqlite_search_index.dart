import 'package:club_core/club_core.dart';
import 'package:drift/drift.dart';

import 'database.dart';

/// SQLite FTS5 implementation of package and visual-group catalog search.
class SqliteSearchIndex implements SearchIndex {
  SqliteSearchIndex(this._db);

  final ClubDatabase _db;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<bool> isReady() async {
    try {
      await _db.select('SELECT COUNT(*) as cnt FROM package_fts');
      await _db.select('SELECT COUNT(*) as cnt FROM package_group_fts');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> indexPackage(IndexDocument doc) async {
    await _db.execute('DELETE FROM package_fts WHERE package_name = ?', [
      doc.package,
    ]);
    await _db.execute(
      '''INSERT INTO package_fts
         (package_name, name, description, readme_excerpt, tags, topics)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        doc.package,
        doc.package,
        doc.description ?? '',
        _truncate(doc.readme, 500),
        doc.tags.join(' '),
        doc.topics.join(' '),
      ],
    );
  }

  @override
  Future<void> indexPackageGroup(PackageGroupIndexDocument document) async {
    await _db.execute('DELETE FROM package_group_fts WHERE group_id = ?', [
      document.id,
    ]);
    await _db.execute(
      '''INSERT INTO package_group_fts (group_id, slug, name, description)
         VALUES (?, ?, ?, ?)''',
      [document.id, document.slug, document.name, document.description ?? ''],
    );
  }

  @override
  Future<void> removePackage(String package) async {
    await _db.execute('DELETE FROM package_fts WHERE package_name = ?', [
      package,
    ]);
  }

  @override
  Future<void> removePackageGroup(String groupId) async {
    await _db.execute('DELETE FROM package_group_fts WHERE group_id = ?', [
      groupId,
    ]);
  }

  @override
  Future<SearchResult> search(
    SearchQuery query, {
    required VisibilityScope scope,
  }) async {
    final text = query.query?.trim() ?? '';
    return text.isEmpty
        ? _listAll(query, scope)
        : _searchText(query, scope, _sanitizeFtsQuery(text));
  }

  Future<SearchResult> _searchText(
    SearchQuery query,
    VisibilityScope scope,
    String ftsQuery,
  ) async {
    final packageFilter = _discoveryFilter(scope, alias: 'p.');
    final directRows = query.entityType == SearchEntityType.packageGroup
        ? const <QueryRow>[]
        : await _db.select(
            '''SELECT fts.package_name AS id, rank, p.updated_at, p.created_at,
                      p.likes_count
               FROM package_fts fts
               JOIN packages p ON p.name = fts.package_name
               WHERE package_fts MATCH ? ${packageFilter.sql}''',
            [ftsQuery, ...packageFilter.args],
          );

    final groupVisibility = _groupDiscoveryExists(scope, groupAlias: 'g');
    final groupRows = query.entityType == SearchEntityType.package
        ? const <QueryRow>[]
        : await _db.select(
            '''SELECT fts.group_id AS id, rank, g.updated_at, g.created_at,
                      0 AS likes_count
               FROM package_group_fts fts
               JOIN package_groups g ON g.id = fts.group_id
               WHERE package_group_fts MATCH ? ${groupVisibility.sql}''',
            [ftsQuery, ...groupVisibility.args],
          );

    // A group-name match also makes its visible member packages match. This
    // is intentionally relational rather than copied into package FTS so the
    // search result can still render a distinct group card.
    final memberRows = query.entityType == SearchEntityType.packageGroup
        ? const <QueryRow>[]
        : await _db.select(
            '''SELECT DISTINCT p.name AS id, gf.rank + 100.0 AS rank,
                      p.updated_at, p.created_at, p.likes_count
               FROM package_group_fts gf
               JOIN package_group_packages gp ON gp.group_id = gf.group_id
               JOIN packages p ON p.name = gp.package_name
               WHERE package_group_fts MATCH ? ${packageFilter.sql}''',
            [ftsQuery, ...packageFilter.args],
          );

    final byKey =
        <
          String,
          ({SearchHit hit, double rank, int updated, int created, int likes})
        >{};
    void addRows(List<QueryRow> rows, SearchEntityType type) {
      for (final row in rows) {
        final id = row.read<String>('id');
        final rank = row.read<double>('rank');
        final key = '${type.name}:$id';
        final value = (
          hit: type == SearchEntityType.package
              ? SearchHit.package(package: id, score: -rank)
              : SearchHit.packageGroup(groupId: id, score: -rank),
          rank: rank,
          updated: row.read<int>('updated_at'),
          created: row.read<int>('created_at'),
          likes: row.read<int>('likes_count'),
        );
        final existing = byKey[key];
        if (existing == null || rank < existing.rank) byKey[key] = value;
      }
    }

    addRows(directRows, SearchEntityType.package);
    addRows(memberRows, SearchEntityType.package);
    addRows(groupRows, SearchEntityType.packageGroup);
    final values = byKey.values.toList()
      ..sort((a, b) => _compare(a, b, query.order));
    return _page(values, query);
  }

  Future<SearchResult> _listAll(
    SearchQuery query,
    VisibilityScope scope,
  ) async {
    final packageFilter = _discoveryFilter(scope, alias: 'p.');
    final packageRows = query.entityType == SearchEntityType.packageGroup
        ? const <QueryRow>[]
        : await _db.select(
            '''SELECT p.name AS id, 0.0 AS rank, p.updated_at, p.created_at,
                      p.likes_count
               FROM packages p WHERE 1=1 ${packageFilter.sql}''',
            packageFilter.args,
          );
    final groupFilter = _groupDiscoveryExists(scope, groupAlias: 'g');
    final groupRows =
        query.entityType == SearchEntityType.package ||
            query.order == SearchOrder.likes
        ? const <QueryRow>[]
        : await _db.select(
            '''SELECT g.id, 0.0 AS rank, g.updated_at, g.created_at,
                      0 AS likes_count
               FROM package_groups g WHERE 1=1 ${groupFilter.sql}''',
            groupFilter.args,
          );

    final values =
        <({SearchHit hit, double rank, int updated, int created, int likes})>[
          for (final row in packageRows)
            (
              hit: SearchHit.package(package: row.read<String>('id')),
              rank: 0,
              updated: row.read<int>('updated_at'),
              created: row.read<int>('created_at'),
              likes: row.read<int>('likes_count'),
            ),
          for (final row in groupRows)
            (
              hit: SearchHit.packageGroup(groupId: row.read<String>('id')),
              rank: 0,
              updated: row.read<int>('updated_at'),
              created: row.read<int>('created_at'),
              likes: 0,
            ),
        ]..sort((a, b) => _compare(a, b, query.order));
    return _page(values, query);
  }

  int _compare(
    ({SearchHit hit, double rank, int updated, int created, int likes}) a,
    ({SearchHit hit, double rank, int updated, int created, int likes}) b,
    SearchOrder order,
  ) {
    final comparison = switch (order) {
      SearchOrder.relevance => a.rank.compareTo(b.rank),
      SearchOrder.updated => b.updated.compareTo(a.updated),
      SearchOrder.created => b.created.compareTo(a.created),
      SearchOrder.likes => b.likes.compareTo(a.likes),
    };
    if (comparison != 0) return comparison;
    return a.hit.identifier.compareTo(b.hit.identifier);
  }

  SearchResult _page(
    List<({SearchHit hit, double rank, int updated, int created, int likes})>
    values,
    SearchQuery query,
  ) {
    final packageCount = values
        .where((v) => v.hit.type == SearchEntityType.package)
        .length;
    final groupCount = values.length - packageCount;
    final start = query.offset.clamp(0, values.length);
    final end = (start + query.limit).clamp(start, values.length);
    return SearchResult(
      hits: values.sublist(start, end).map((v) => v.hit).toList(),
      totalHits: values.length,
      packageHits: packageCount,
      groupHits: groupCount,
    );
  }

  ({String sql, List<Object?> args}) _discoveryFilter(
    VisibilityScope scope, {
    required String alias,
  }) {
    final clauses = [
      'AND ${alias}is_discontinued = 0',
      'AND ${alias}is_unlisted = 0',
      if (scope.publicOnly) 'AND ${alias}visibility = ?',
    ];
    return (
      sql: clauses.join(' '),
      args: scope.publicOnly
          ? [PackageVisibility.public.wireName]
          : const <Object?>[],
    );
  }

  ({String sql, List<Object?> args}) _groupDiscoveryExists(
    VisibilityScope scope, {
    required String groupAlias,
  }) {
    final packageFilter = _discoveryFilter(scope, alias: 'p.');
    return (
      sql:
          '''AND EXISTS (
        SELECT 1 FROM package_group_packages gp
        JOIN packages p ON p.name = gp.package_name
        WHERE gp.group_id = $groupAlias.id ${packageFilter.sql}
      )''',
      args: packageFilter.args,
    );
  }

  @override
  Future<void> reindex(Stream<IndexDocument> documents) async {
    await _db.execute('DELETE FROM package_fts');
    await for (final doc in documents) {
      await indexPackage(doc);
    }
  }

  static String _sanitizeFtsQuery(String input) {
    final tokens = input.trim().split(RegExp(r'\s+'));
    return tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
  }

  static String _truncate(String? value, int maxLength) {
    if (value == null) return '';
    return value.length <= maxLength ? value : value.substring(0, maxLength);
  }
}
