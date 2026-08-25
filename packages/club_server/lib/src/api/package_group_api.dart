import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import 'list_info.dart';

/// Public browsing and authenticated management for visual package groups.
class PackageGroupApi {
  PackageGroupApi({
    required this.service,
    required this.metadataStore,
    required this.packageService,
  });

  final PackageGroupService service;
  final MetadataStore metadataStore;
  final PackageService packageService;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/groups', _list);
    router.post('/api/groups', _create);
    router.get('/api/groups/<slug>', _get);
    router.put('/api/groups/<groupId>', _update);
    router.delete('/api/groups/<groupId>', _delete);
    router.get('/api/groups/<slug>/packages', _packages);
    router.post('/api/groups/<groupId>/packages', _addPackage);
    router.delete('/api/groups/<groupId>/packages/<package>', _removePackage);
    router.put('/api/groups/<groupId>/packages/order', _reorder);
    router.put('/api/groups/<groupId>/packages', _replacePackages);
    return router;
  }

  Future<Response> _list(Request request) async {
    final scope = visibilityScopeFor(request);
    final result = await metadataStore.listPackageGroups(
      scope: scope,
      pageToken: request.url.queryParameters['page'],
      query: request.url.queryParameters['q'],
      includeEmpty: !scope.publicOnly,
    );
    final groups = await Future.wait(
      result.items.map((g) => _groupJson(g, request, includePreview: true)),
    );
    return _json({
      'groups': groups,
      'totalCount': result.totalCount,
      'nextPageToken': result.nextPageToken,
    });
  }

  Future<Response> _get(Request request, String slug) async {
    final group = await metadataStore.lookupPackageGroupBySlug(slug);
    if (group == null) throw NotFoundException.packageGroup(slug);
    final packagePage = await metadataStore.listPackagesForGroup(
      group.id,
      scope: visibilityScopeFor(request),
      limit: 1,
    );
    if (visibilityScopeFor(request).publicOnly && packagePage.totalCount == 0) {
      throw NotFoundException.packageGroup(slug);
    }
    return _json(await _groupJson(group, request));
  }

  Future<Response> _packages(Request request, String slug) async {
    final group = await metadataStore.lookupPackageGroupBySlug(slug);
    if (group == null) throw NotFoundException.packageGroup(slug);
    final result = await metadataStore.listPackagesForGroup(
      group.id,
      scope: visibilityScopeFor(request),
      pageToken: request.url.queryParameters['page'],
      includeUnlisted:
          request.url.queryParameters['includeUnlisted'] == '1' &&
          getAuthUser(request) != null,
    );
    return _json({
      'packages': await Future.wait(
        result.items.map(
          (package) => _packageJson(
            package,
            request,
            scope: visibilityScopeFor(request),
          ),
        ),
      ),
      'totalCount': result.totalCount,
      'nextPageToken': result.nextPageToken,
    });
  }

  Future<Response> _create(Request request) async {
    final user = requireAuthUser(request);
    final body = await _body(request);
    final group = await service.create(
      name: body['name'] as String? ?? '',
      description: body['description'] as String?,
      publisherId: body['publisherId'] as String?,
      actingUserId: user.userId,
    );
    return _json(await _groupJson(group, request), status: 201);
  }

  Future<Response> _update(Request request, String groupId) async {
    final user = requireAuthUser(request);
    final body = await _body(request);
    final group = await service.update(
      groupId,
      name: body['name'] as String? ?? '',
      description: body['description'] as String?,
      actingUserId: user.userId,
    );
    return _json(await _groupJson(group, request));
  }

  Future<Response> _delete(Request request, String groupId) async {
    final user = requireAuthUser(request);
    await service.delete(groupId, actingUserId: user.userId);
    return _json({'status': 'ok'});
  }

  Future<Response> _addPackage(Request request, String groupId) async {
    final user = requireAuthUser(request);
    final body = await _body(request);
    final package = body['package'] as String? ?? '';
    await service.addPackage(groupId, package, actingUserId: user.userId);
    return _json({'status': 'ok'});
  }

  Future<Response> _removePackage(
    Request request,
    String groupId,
    String package,
  ) async {
    final user = requireAuthUser(request);
    await service.removePackage(groupId, package, actingUserId: user.userId);
    return _json({'status': 'ok'});
  }

  Future<Response> _replacePackages(Request request, String groupId) async {
    final user = requireAuthUser(request);
    final body = await _body(request);
    final packageNames = (body['packages'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    await service.replacePackages(
      groupId,
      packageNames,
      actingUserId: user.userId,
    );
    return _json({'status': 'ok'});
  }

  Future<Response> _reorder(Request request, String groupId) async {
    final user = requireAuthUser(request);
    final body = await _body(request);
    final packageNames = (body['packages'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList();
    await service.reorder(
      groupId,
      packageNames,
      actingUserId: user.userId,
    );
    return _json({'status': 'ok'});
  }

  Future<Map<String, dynamic>> _groupJson(
    PackageGroup group,
    Request request, {
    bool includePreview = false,
  }) async {
    final scope = visibilityScopeFor(request);
    final packages = await metadataStore.listPackagesForGroup(
      group.id,
      scope: scope,
      limit: includePreview ? 7 : 1,
    );
    final authUser = getAuthUser(request);
    final canManage =
        authUser != null && await service.canManage(group.id, authUser.userId);
    String ownerName;
    if (group.publisherId != null) {
      ownerName =
          (await metadataStore.lookupPublisher(
            group.publisherId!,
          ))?.displayName ??
          group.publisherId!;
    } else {
      ownerName =
          (await metadataStore.lookupUserById(
            group.ownerUserId!,
          ))?.displayName ??
          'User';
    }
    return {
      ...group.toJson(),
      'owner': {
        'type': group.publisherId != null ? 'publisher' : 'user',
        'id': group.publisherId ?? group.ownerUserId,
        'displayName': ownerName,
      },
      'packageCount': packages.totalCount,
      if (includePreview)
        'previewPackages': await Future.wait(
          packages.items.map(_previewPackageJson),
        ),
      'canManage': canManage,
    };
  }

  Future<Map<String, dynamic>> _previewPackageJson(Package package) async {
    final versionName = package.latestVersion ?? package.latestPrerelease ?? '';
    var description = '';
    if (versionName.isNotEmpty) {
      final version = await metadataStore.lookupVersion(
        package.name,
        versionName,
      );
      description = version?.pubspecMap['description'] as String? ?? '';
    }
    return {
      'name': package.name,
      'version': versionName,
      'description': description,
    };
  }

  Future<Map<String, dynamic>> _packageJson(
    Package package,
    Request request, {
    required VisibilityScope scope,
  }) async {
    final versionName = package.latestVersion ?? package.latestPrerelease;
    String? description;
    String? dartSdk;
    String? flutterSdk;
    String? repository;
    String? homepage;
    var topics = const <String>[];

    if (versionName != null) {
      final version = await metadataStore.lookupVersion(
        package.name,
        versionName,
      );
      final pubspec = version?.pubspecMap;
      if (pubspec != null) {
        description = pubspec['description'] as String?;
        repository = pubspec['repository'] as String?;
        homepage = pubspec['homepage'] as String?;
        final rawTopics = pubspec['topics'];
        if (rawTopics is List) {
          topics = rawTopics.whereType<String>().toList();
        }
        final environment = pubspec['environment'];
        if (environment is Map) {
          dartSdk = environment['sdk'] as String?;
          flutterSdk = environment['flutter'] as String?;
        }
      }
    }

    final score = await packageService.getScore(package.name);
    final listInfo = await buildListInfo(
      metadataStore,
      packageService,
      request,
      package.name,
      scope: scope,
    );
    final uploaders = listInfo?['uploaders'];
    final firstUploader = uploaders is List && uploaders.isNotEmpty
        ? uploaders.first
        : null;

    return {
      'name': package.name,
      'description': description ?? '',
      'version': versionName ?? '',
      'likes': score.likeCount,
      'points': score.grantedPoints,
      'maxPoints': score.maxPoints,
      'downloads': score.downloadCount30Days,
      'tags': score.tags,
      'topics': topics,
      'publishedAt': package.updatedAt.toIso8601String(),
      'dartSdk': dartSdk,
      'flutterSdk': flutterSdk,
      'repository': repository,
      'homepage': homepage,
      'isDiscontinued': package.isDiscontinued,
      'isUnlisted': package.isUnlisted,
      'publisher': listInfo?['publisher'],
      'uploader': firstUploader,
      'license': listInfo?['license'],
      'screenshots': listInfo?['screenshots'] ?? const <Object>[],
    };
  }

  Future<Map<String, dynamic>> _body(Request request) async =>
      jsonDecode(await request.readAsString()) as Map<String, dynamic>;

  Response _json(Object data, {int status = 200}) => Response(
    status,
    body: jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );
}
