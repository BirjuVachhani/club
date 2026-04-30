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
  Future<SearchResult> search(SearchQuery query) async {
    if (query.query == null || query.query!.trim().isEmpty) {
      return _listAll(query);
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
        orderBy = 'ORDER BY p.created_at ASC';
    }

    // Discontinued packages are excluded from search results (per pub.dev
    // spec). Unlisted packages remain findable by name via search.
    final sql =
        '''
      SELECT fts.package_name, rank
      FROM package_fts fts
      JOIN packages p ON p.name = fts.package_name
      WHERE package_fts MATCH ? AND p.is_discontinued = 0
      $orderBy
      LIMIT ? OFFSET ?
    ''';

    final rows = await _db.select(sql, [ftsQuery, query.limit, query.offset]);

    // Count total hits.
    const countSql = '''
      SELECT COUNT(*) as cnt
      FROM package_fts fts
      JOIN packages p ON p.name = fts.package_name
      WHERE package_fts MATCH ? AND p.is_discontinued = 0
    ''';
    final countRows = await _db.select(countSql, [ftsQuery]);
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

  /// When there is no search query, list packages by the requested order.
  /// Unlisted and discontinued packages are excluded from browse results —
  /// unlisted packages remain findable via the FTS search path (and via My
  /// Packages / publisher pages); discontinued packages are viewable only by
  /// direct URL.
  Future<SearchResult> _listAll(SearchQuery query) async {
    String orderBy;
    switch (query.order) {
      case SearchOrder.relevance:
      case SearchOrder.updated:
        orderBy = 'ORDER BY updated_at DESC';
      case SearchOrder.likes:
        orderBy = 'ORDER BY likes_count DESC';
      case SearchOrder.created:
        orderBy = 'ORDER BY created_at ASC';
    }

    const where = 'WHERE is_unlisted = 0 AND is_discontinued = 0';

    final rows = await _db.select(
      'SELECT name FROM packages $where $orderBy LIMIT ? OFFSET ?',
      [query.limit, query.offset],
    );

    final countRows = await _db.select(
      'SELECT COUNT(*) as cnt FROM packages $where',
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
