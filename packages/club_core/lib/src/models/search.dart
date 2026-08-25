import 'package_group.dart';

/// A package document to be indexed.
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

/// Searchable fields for a visual package group.
class PackageGroupIndexDocument {
  const PackageGroupIndexDocument({
    required this.id,
    required this.slug,
    required this.name,
    this.description,
  });

  factory PackageGroupIndexDocument.fromGroup(PackageGroup group) =>
      PackageGroupIndexDocument(
        id: group.id,
        slug: group.slug,
        name: group.name,
        description: group.description,
      );

  final String id;
  final String slug;
  final String name;
  final String? description;
}

enum SearchOrder { relevance, updated, likes, created }

enum SearchEntityType { package, packageGroup }

class SearchQuery {
  const SearchQuery({
    this.query,
    this.tags = const [],
    this.order = SearchOrder.relevance,
    this.entityType,
    this.offset = 0,
    this.limit = 20,
  });

  final String? query;
  final List<String> tags;
  final SearchOrder order;
  final SearchEntityType? entityType;
  final int offset;
  final int limit;
}

/// A package or group returned by catalog search.
class SearchHit {
  const SearchHit.package({required String package, this.score = 0.0})
    : type = SearchEntityType.package,
      identifier = package;

  const SearchHit.packageGroup({required String groupId, this.score = 0.0})
    : type = SearchEntityType.packageGroup,
      identifier = groupId;

  final SearchEntityType type;
  final String identifier;
  final double score;

  /// Backwards-compatible package name accessor for package hits.
  String get package => identifier;
  String get groupId => identifier;
}

class SearchResult {
  const SearchResult({
    required this.hits,
    this.totalHits = -1,
    this.packageHits = -1,
    this.groupHits = -1,
  });

  final List<SearchHit> hits;
  final int totalHits;
  final int packageHits;
  final int groupHits;
}
