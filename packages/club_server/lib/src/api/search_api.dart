import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';

/// Search and package discovery API handlers.
class SearchApi {
  SearchApi({
    required this.searchIndex,
    required this.metadataStore,
  });

  final SearchIndex searchIndex;
  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/search', _search);
    router.get('/api/package-name-completion-data', _completionData);
    router.get('/api/packages', _listPackages);
    return router;
  }

  Future<Response> _search(Request request) async {
    final q = request.url.queryParameters['q'];
    final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
    final sortStr = request.url.queryParameters['sort'] ?? 'relevance';

    final order = switch (sortStr) {
      'updated' => SearchOrder.updated,
      'created' => SearchOrder.created,
      'likes' => SearchOrder.likes,
      _ => SearchOrder.relevance,
    };

    const pageSize = 20;
    final result = await searchIndex.search(
      SearchQuery(
        query: q,
        order: order,
        offset: (page - 1) * pageSize,
        limit: pageSize,
      ),
    );

    return Response.ok(
      jsonEncode({
        'packages': result.hits
            .map((h) => {'package': h.package, 'score': h.score})
            .toList(),
        'totalCount': result.totalHits,
        'page': page,
        'pageSize': pageSize,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _completionData(Request request) async {
    final packages = await metadataStore.listPackages(limit: 10000);
    return Response.ok(
      jsonEncode({
        'packages': packages.items.map((p) => p.name).toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _listPackages(Request request) async {
    final page = request.url.queryParameters['page'];
    final compact = request.url.queryParameters['compact'];

    if (compact == '1') {
      return _completionData(request);
    }

    final packages = await metadataStore.listPackages(
      limit: 100,
      pageToken: page,
    );
    return Response.ok(
      jsonEncode({
        'packages': packages.items.map((p) => p.name).toList(),
        'totalCount': packages.totalCount,
      }),
      headers: {'content-type': 'application/json'},
    );
  }
}
