import 'package:club_core/club_core.dart';

import 'database.dart';

/// SQLite FTS5 implementation of [SearchIndex].
class SqliteSearchIndex implements SearchIndex {
  SqliteSearchIndex(this._db);

  final ClubDatabase _db;

  @override
  Future<void> open() async {
    // Database and FTS table are created during migration startup.
  }

  @override
  Future<void> close() async {
    // Closed by ClubDatabase.
  }

  @override
  Future<bool> isReady() async {
    // Ready once the FTS table exists. We just try to query it.
    try {
      await _db.select('SELECT COUNT(*) as cnt FROM package_fts');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> indexPackage(IndexDocument doc) async {
    // Delete existing entry first (FTS5 doesn't support UPSERT).
    await _db.execute(
      'DELETE FROM package_fts WHERE package_name = ?',
      [doc.package],
    );

    final readmeExcerpt = _truncate(doc.readme, 500);
    final tags = doc.tags.join(' ');
    final topics = doc.topics.join(' ');

    await _db.execute(
      '''INSERT INTO package_fts
         (package_name, name, description, readme_excerpt, tags, topics)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        doc.package,
        doc.package,
        doc.description ?? '',
        readmeExcerpt,
        tags,
        topics,
      ],
    );
  }

  @override
  Future<void> removePackage(String package) async {
    await _db.execute(
      'DELETE FROM package_fts WHERE package_name = ?',
      [package],
    );
  }

  @override
  Future<SearchResult> search(
    SearchQuery query, {
    required VisibilityScope scope,
  }) async {
    if (query.query == null || query.query!.trim().isEmpty) {
      return _listAll(query, scope);
    }

    // FTS5 MATCH query with rank ordering.
    final ftsQuery = _sanitizeFtsQuery(query.query!);

    String orderBy;
    switch (query.order) {
      case SearchOrder.relevance:
        orderBy = 'ORDER BY rank';
      case SearchOrder.updated:
        orderBy = 'ORDER BY p.updated_at DESC';
      case SearchOrder.likes:
        orderBy = 'ORDER BY p.likes_count DESC';
      case SearchOrder.created:
        orderBy = 'ORDER BY p.created_at DESC';
    }

    // Same predicate as the browse path below, built once so the two
    // cannot drift. They did drift before: keyword search returned
    // unlisted packages that browse hid, which meant "unlisted" depended
    // on whether you happened to type something in the box.
    //
    // Applied to the page query and the count query alike. Filtering only
    // the page would still leak the number of matching hidden packages,
    // which is enough to confirm a guessed name.
    final filter = _discoveryFilter(scope, alias: 'p.');

    final sql =
        '''
      SELECT fts.package_name, rank
      FROM package_fts fts
      JOIN packages p ON p.name = fts.package_name
      WHERE package_fts MATCH ? ${filter.sql}
      $orderBy
      LIMIT ? OFFSET ?
    ''';

    final rows = await _db.select(sql, [
      ftsQuery,
      ...filter.args,
      query.limit,
      query.offset,
    ]);

    // Count total hits.
    final countSql =
        '''
      SELECT COUNT(*) as cnt
      FROM package_fts fts
      JOIN packages p ON p.name = fts.package_name
      WHERE package_fts MATCH ? ${filter.sql}
    ''';
    final countRows = await _db.select(countSql, [
      ftsQuery,
      ...filter.args,
    ]);
    final totalHits = countRows.first.read<int>('cnt');

    final hits = rows.map((r) {
      return SearchHit(
        package: r.read<String>('package_name'),
        score: -(r.read<double>('rank')), // FTS5 rank is negative
      );
    }).toList();

    return SearchResult(hits: hits, totalHits: totalHits);
  }

  @override
  Future<void> reindex(Stream<IndexDocument> documents) async {
    await _db.execute('DELETE FROM package_fts');
    await for (final doc in documents) {
      await indexPackage(doc);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// The predicate deciding whether a package may appear in any discovery
  /// result: keyword search, browse, or autocomplete.
  ///
  /// Three independent reasons a package is excluded:
  ///
  /// - `is_discontinued`: pub.dev semantics. Still reachable by URL.
  /// - `is_unlisted`: the author asked for it not to be listed. That means
  ///   findable by URL only, so it is excluded from *every* discovery
  ///   surface rather than just browse. Keeping it out of one and not the
  ///   other made "unlisted" depend on whether the visitor happened to
  ///   type a query.
  /// - `visibility`: access control. Under an anonymous scope only public
  ///   packages exist at all.
  ///
  /// The first two are listing hints and apply to everyone, including
  /// signed-in users. Neither hides the package: a direct URL still works,
  /// and My Packages and publisher pages use different queries that do not
  /// go through here.
  ///
  /// [alias] is the table qualifier to use (`'p.'` when joined, `''` when
  /// querying `packages` directly).
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

  /// When there is no search query, list packages by the requested order.
  /// Same exclusions as the keyword path; see [_discoveryFilter].
  Future<SearchResult> _listAll(SearchQuery query, VisibilityScope scope) async {
    String orderBy;
    switch (query.order) {
      case SearchOrder.relevance:
      case SearchOrder.updated:
        orderBy = 'ORDER BY updated_at DESC';
      case SearchOrder.likes:
        orderBy = 'ORDER BY likes_count DESC';
      case SearchOrder.created:
        orderBy = 'ORDER BY created_at DESC';
    }

    final filter = _discoveryFilter(scope, alias: '');
    // The leading `AND` from the shared builder needs a left operand.
    final where = 'WHERE 1=1 ${filter.sql}';

    final rows = await _db.select(
      'SELECT name FROM packages $where $orderBy LIMIT ? OFFSET ?',
      [...filter.args, query.limit, query.offset],
    );

    final countRows = await _db.select(
      'SELECT COUNT(*) as cnt FROM packages $where',
      [...filter.args],
    );
    final totalHits = countRows.first.read<int>('cnt');

    final hits = rows.map((r) {
      return SearchHit(package: r.read<String>('name'));
    }).toList();

    return SearchResult(hits: hits, totalHits: totalHits);
  }

  /// Sanitize user input for FTS5 MATCH. Wraps each token in double quotes
  /// to prevent injection and handles special characters.
  static String _sanitizeFtsQuery(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '""';

    // Split on whitespace, quote each token, join with spaces (implicit AND).
    final tokens = trimmed.split(RegExp(r'\s+'));
    return tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
  }

  static String _truncate(String? s, int maxLength) {
    if (s == null) return '';
    return s.length <= maxLength ? s : s.substring(0, maxLength);
  }
}
