import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';

/// Per-user account API: "my packages", "my publishers", "my activity".
///
/// These endpoints always operate on the authenticated user — they never
/// take a user id in the path. This keeps permission checks trivial: if
/// the caller is signed in, they can see their own stuff.
class AccountApi {
  AccountApi({required this.metadataStore});

  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/account/packages', _myPackages);
    router.get('/api/account/publishers', _myPublishers);
    router.get('/api/account/activity-log', _myActivity);
    return router;
  }

  /// Packages where the user is an uploader or a member of the owning
  /// publisher. Supports `?q=` filter and `?page=` cursor.
  Future<Response> _myPackages(Request request) async {
    final user = requireAuthUser(request);
    final query = request.url.queryParameters['q'];
    final page = request.url.queryParameters['page'];

    final result = await metadataStore.listPackagesForUser(
      user.userId,
      limit: 50,
      pageToken: page,
      query: query,
    );

    final enriched = <Map<String, dynamic>>[];
    for (final p in result.items) {
      enriched.add(await _packageJsonWithPubspec(p));
    }

    return _json({
      'packages': enriched,
      'totalCount': result.totalCount,
      'nextPageToken': result.nextPageToken,
    });
  }

  /// Publishers the user is a member of.
  Future<Response> _myPublishers(Request request) async {
    final user = requireAuthUser(request);
    final publishers = await metadataStore.listPublishersForUser(user.userId);

    // Attach the caller's role in each publisher so the UI can gate
    // member-management buttons without a second round-trip.
    final items = <Map<String, dynamic>>[];
    for (final p in publishers) {
      final isAdmin = await metadataStore.isPublisherAdmin(p.id, user.userId);
      items.add({
        'publisherId': p.id,
        'displayName': p.displayName,
        'description': p.description,
        'websiteUrl': p.websiteUrl,
        'contactEmail': p.contactEmail,
        'createdAt': p.createdAt.toIso8601String(),
        'role': isAdmin ? PublisherRole.admin : PublisherRole.member,
      });
    }

    return _json({'publishers': items});
  }

  /// Cross-package activity for the signed-in user. Events where this
  /// user was the agent (publisher created, uploader added, version
  /// published, etc.). Cursor-paginated via ISO-8601 `before`.
  Future<Response> _myActivity(Request request) async {
    final user = requireAuthUser(request);
    final beforeStr = request.url.queryParameters['before'];
    final before = beforeStr != null ? DateTime.tryParse(beforeStr) : null;

    final records = await metadataStore.queryAuditLog(
      agentId: user.userId,
      limit: 50,
      before: before,
    );

    final entries = records
        .map(
          (r) => {
            'id': r.id,
            'createdAt': r.createdAt.toIso8601String(),
            'kind': r.kind,
            'summary': r.summary,
            if (r.packageName != null) 'package': r.packageName,
            if (r.version != null) 'version': r.version,
            if (r.publisherId != null) 'publisherId': r.publisherId,
          },
        )
        .toList();

    return _json({'entries': entries});
  }

  Future<Map<String, dynamic>> _packageJsonWithPubspec(Package p) async {
    String? description;
    String? dartSdk;
    String? flutterSdk;
    String? repository;
    String? homepage;

    final latest = p.latestVersion;
    if (latest != null) {
      final version = await metadataStore.lookupVersion(p.name, latest);
      if (version != null) {
        final pubspec = version.pubspecMap;
        description = pubspec['description'] as String?;
        repository = pubspec['repository'] as String?;
        homepage = pubspec['homepage'] as String?;
        final env = pubspec['environment'];
        if (env is Map) {
          dartSdk = env['sdk'] as String?;
          flutterSdk = env['flutter'] as String?;
        }
      }
    }

    return {
      'name': p.name,
      'publisherId': p.publisherId,
      'latestVersion': p.latestVersion,
      'latestPrerelease': p.latestPrerelease,
      'likesCount': p.likesCount,
      'isDiscontinued': p.isDiscontinued,
      'isUnlisted': p.isUnlisted,
      'updatedAt': p.updatedAt.toIso8601String(),
      if (description != null && description.isNotEmpty)
        'description': description,
      'dartSdk': ?dartSdk,
      'flutterSdk': ?flutterSdk,
      'repository': ?repository,
      'homepage': ?homepage,
    };
  }

  Response _json(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );
}
