/// A document to be indexed in the search index.
class IndexDocument {
  const IndexDocument({
    required this.package,
    this.latestVersion,
    this.description,
    this.readme,
    this.tags = const [],
    this.topics = const [],
    this.likeCount = 0,
    required this.publishedAt,
    required this.updatedAt,
  });

  final String package;
  final String? latestVersion;
  final String? description;
  final String? readme;
  final List<String> tags;
  final List<String> topics;
  final int likeCount;
  final DateTime publishedAt;
  final DateTime updatedAt;
}

/// Sort order for search results.
///
/// Every order except [relevance] is newest/highest first: these back
/// "Recently Updated", "Most Likes", and "Recently Added" surfaces, where the
/// point is to show what just happened. In particular [created] means *most
/// recently created first*, not oldest first.
enum SearchOrder {
  /// FTS rank. Falls back to [updated] when there is no query to rank against.
  relevance,

  /// Most recently published to, descending.
  updated,

  /// Most liked, descending.
  likes,

  /// Most recently added to the repository, descending.
  created,
}

/// Input to a search query.
class SearchQuery {
  const SearchQuery({
    this.query,
    this.tags = const [],
    this.order = SearchOrder.relevance,
    this.offset = 0,
    this.limit = 20,
  });

  final String? query;
  final List<String> tags;
  final SearchOrder order;
  final int offset;
  final int limit;
}

/// A single hit in search results.
class SearchHit {
  const SearchHit({required this.package, this.score = 0.0});

  final String package;
  final double score;
}

/// Full search result page.
class SearchResult {
  const SearchResult({
    required this.hits,
    this.totalHits = -1,
  });

  final List<SearchHit> hits;
  final int totalHits;
}
