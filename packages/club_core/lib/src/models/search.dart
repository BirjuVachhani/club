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
enum SearchOrder { relevance, updated, likes, created }

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
