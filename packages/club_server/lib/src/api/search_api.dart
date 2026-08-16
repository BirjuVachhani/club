import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import '../middleware/request_url.dart';
import 'list_info.dart';

/// Search and package discovery API handlers.
class SearchApi {
  SearchApi({
    required this.searchIndex,
    required this.metadataStore,
    required this.packageService,
  });

  final SearchIndex searchIndex;
  final MetadataStore metadataStore;
  final PackageService packageService;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/search', _search);
    router.get('/api/discover', _discover);
    router.get('/api/package-name-completion-data', _completionData);
    router.get('/api/packages', _listPackages);
    return router;
  }

  static const _pageSize = 20;

  SearchOrder _orderOf(String sort) => switch (sort) {
    'updated' => SearchOrder.updated,
    'created' => SearchOrder.created,
    'likes' => SearchOrder.likes,
    _ => SearchOrder.relevance,
  };

  Future<Response> _search(Request request) async {
    final q = request.url.queryParameters['q'];
    final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
    final sortStr = request.url.queryParameters['sort'] ?? 'relevance';

    final result = await searchIndex.search(
      SearchQuery(
        query: q,
        order: _orderOf(sortStr),
        offset: (page - 1) * _pageSize,
        limit: _pageSize,
      ),
      scope: visibilityScopeFor(request),
    );

    return Response.ok(
      jsonEncode({
        'packages': result.hits
            .map((h) => {'package': h.package, 'score': h.score})
            .toList(),
        'totalCount': result.totalHits,
        'page': page,
        'pageSize': _pageSize,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Search plus per-result enrichment in a single round-trip.
  ///
  /// Each hit carries the same `data` (package), `scoreInfo`, and
  /// `listInfo` payloads the web UI already maps, bundled here so list
  /// pages avoid an N+1 of follow-up fetches. Server-side these are cheap
  /// local store reads; from the browser they were N HTTP round-trips.
  Future<Response> _discover(Request request) async {
    final q = request.url.queryParameters['q'];
    final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
    final sortStr = request.url.queryParameters['sort'] ?? 'relevance';

    final scope = visibilityScopeFor(request);
    final result = await searchIndex.search(
      SearchQuery(
        query: q,
        order: _orderOf(sortStr),
        offset: (page - 1) * _pageSize,
        limit: _pageSize,
      ),
      scope: scope,
    );

    final baseUrl = resolveBaseUrl(request);
    final packages = await Future.wait(
      result.hits.map((h) async {
        try {
          final data = await packageService.listVersions(
            h.package,
            baseUrl: baseUrl,
            scope: scope,
          );
          final score = await packageService.getScore(h.package);
          final listInfo = await buildListInfo(
            metadataStore,
            packageService,
            request,
            h.package,
            scope: scope,
          );
          return {
            'package': h.package,
            'score': h.score,
            'data': data.toJson(),
            'scoreInfo': score.toJson(),
            'listInfo': listInfo,
          };
        } catch (_) {
          // Tolerate a single bad package: return the bare hit so the
          // client can still render a minimal row for it.
          return {'package': h.package, 'score': h.score};
        }
      }),
    );

    return Response.ok(
      jsonEncode({
        'packages': packages,
        'totalCount': result.totalHits,
        'page': page,
        'pageSize': _pageSize,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Every discoverable package name on the server, for autocomplete.
  ///
  /// This is an enumeration API by design, which makes the scope the only
  /// thing standing between an anonymous caller and a full catalogue of
  /// private package names. `GET /api/packages?compact=1` shares this
  /// handler, so both are covered by the one filter.
  ///
  /// Unlisted packages are excluded: they are meant to be reachable by URL
  /// only, and an autocomplete that suggests the name defeats that. They
  /// remain fully usable by anyone who knows the name.
  Future<Response> _completionData(Request request) async {
    final packages = await metadataStore.listPackages(
      limit: 10000,
      scope: visibilityScopeFor(request),
      includeUnlisted: false,
    );
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

    // A browse listing, so it follows the same discovery rules as search:
    // unlisted packages are reachable by URL, not by enumeration.
    final packages = await metadataStore.listPackages(
      limit: 100,
      pageToken: page,
      scope: visibilityScopeFor(request),
      includeUnlisted: false,
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
