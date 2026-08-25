import '../models/search.dart';
import 'visibility_scope.dart';

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

  /// Index or re-index a visual package group.
  Future<void> indexPackageGroup(PackageGroupIndexDocument document);

  /// Remove a visual package group from the index.
  Future<void> removePackageGroup(String groupId);

  /// Remove a package from the index.
  Future<void> removePackage(String package);

  /// Execute a search query.
  /// [scope] is required: search is the widest collection read in the
  /// server, and a missed filter here leaks the existence, name, and
  /// description of every private package at once.
  Future<SearchResult> search(
    SearchQuery query, {
    required VisibilityScope scope,
  });

  /// Completely rebuild the index from scratch.
  Future<void> reindex(Stream<IndexDocument> documents);
}
