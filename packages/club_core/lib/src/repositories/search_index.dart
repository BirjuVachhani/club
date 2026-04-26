import '../models/search.dart';

/// Abstract interface for package search.
///
/// Implementations: SqliteSearchIndex (FTS5), MeilisearchIndex.
abstract interface class SearchIndex {
  Future<void> open();
  Future<void> close();

  /// Returns true when the index has been populated and is ready.
  Future<bool> isReady();

  /// Index or re-index a single package document.
  Future<void> indexPackage(IndexDocument doc);

  /// Remove a package from the index.
  Future<void> removePackage(String package);

  /// Execute a search query.
  Future<SearchResult> search(SearchQuery query);

  /// Completely rebuild the index from scratch.
  Future<void> reindex(Stream<IndexDocument> documents);
}
