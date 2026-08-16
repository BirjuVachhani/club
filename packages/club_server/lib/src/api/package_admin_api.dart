import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';
import 'list_info.dart';

/// Package administration API: options, uploaders, publishers.
class PackageAdminApi {
  PackageAdminApi({
    required this.packageService,
    required this.metadataStore,
    required this.blobStore,
    required this.visibilityService,
  });

  final PackageService packageService;
  final MetadataStore metadataStore;
  final BlobStore blobStore;
  final VisibilityService visibilityService;

  /// Refuse a removal that would break public packages, unless the caller
  /// has explicitly accepted it via `?acceptBreakage=true`.
  ///
  /// A public package whose dependency disappears stops resolving for
  /// every anonymous consumer, and unlike a visibility flip there is
  /// nothing to switch back. The error names the chains so the person
  /// deciding can see which packages they are about to break and how the
  /// breakage reaches them.
  Future<void> _guardBreakage(
    Request request,
    String package, {
    required String action,
  }) async {
    if (request.url.queryParameters['acceptBreakage'] == 'true') return;

    final dependents = await visibilityService.breakageFromRemoving(package);
    if (dependents.isEmpty) return;

    final summary = dependents
        .take(5)
        .map((d) => d.pathDescription)
        .join('; ');
    throw ConflictException(
      '$action breaks ${dependents.length} public package(s) that depend '
      'on it: $summary${dependents.length > 5 ? '; ...' : ''}. '
      'Re-send with ?acceptBreakage=true to proceed anyway.',
    );
  }

  DecodedRouter get router {
    final router = DecodedRouter();

    router.get('/api/packages/<package>/options', _getOptions);
    router.put('/api/packages/<package>/options', _setOptions);
    router.get(
      '/api/packages/<package>/versions/<version>/options',
      _getVersionOptions,
    );
    router.put(
      '/api/packages/<package>/versions/<version>/options',
      _setVersionOptions,
    );
    router.get('/api/packages/<package>/uploaders', _getUploaders);
    router.put('/api/packages/<package>/uploaders/<email>', _addUploader);
    router.delete('/api/packages/<package>/uploaders/<email>', _removeUploader);
    router.get('/api/packages/<package>/publisher', _getPublisher);
    router.put('/api/packages/<package>/publisher', _setPublisher);
    router.get('/api/packages/<package>/likes', _getLikes);
    router.get('/api/packages/<package>/permissions', _getPermissions);
    router.get('/api/packages/<package>/activity-log', _getActivityLog);
    router.get('/api/packages/<package>/list-info', _getListInfo);
    router.delete('/api/packages/<package>', _deletePackage);

    return router;
  }

  /// Aggregated metadata used by the web UI's package list row. Bundles
  /// publisher, uploaders, and license into a single call so list pages
  /// don't need N separate fetches per result.
  Future<Response> _getListInfo(Request request, String package) async {
    final info = await buildListInfo(
      metadataStore,
      packageService,
      request,
      package,
      scope: visibilityScopeFor(request),
    );
    if (info == null) throw NotFoundException.package(package);
    return _json(info);
  }

  Future<Response> _getOptions(Request request, String package) async {
    final pkg = await packageService.getPackage(package);
    return _json({
      'isDiscontinued': pkg.isDiscontinued,
      'replacedBy': pkg.replacedBy,
      'isUnlisted': pkg.isUnlisted,
    });
  }

  Future<Response> _setOptions(Request request, String package) async {
    final user = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    final updated = await packageService.setOptions(
      package,
      isDiscontinued: body['isDiscontinued'] as bool?,
      replacedBy: body['replacedBy'] as String?,
      isUnlisted: body['isUnlisted'] as bool?,
      actingUserId: user.userId,
    );

    return _json({
      'isDiscontinued': updated.isDiscontinued,
      'replacedBy': updated.replacedBy,
      'isUnlisted': updated.isUnlisted,
    });
  }

  Future<Response> _getVersionOptions(
    Request request,
    String package,
    String version,
  ) async {
    final pv = await metadataStore.lookupVersion(package, version);
    if (pv == null) throw NotFoundException.version(package, version);
    return _json({'isRetracted': pv.isRetracted});
  }

  Future<Response> _setVersionOptions(
    Request request,
    String package,
    String version,
  ) async {
    final user = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final isRetracted = body['isRetracted'] as bool?;

    if (isRetracted != null) {
      await packageService.setVersionRetracted(
        package,
        version,
        isRetracted: isRetracted,
        actingUserId: user.userId,
      );
    }

    final pv = await metadataStore.lookupVersion(package, version);
    return _json({'isRetracted': pv?.isRetracted ?? false});
  }

  Future<Response> _getUploaders(Request request, String package) async {
    final uploaderIds = await packageService.getUploaders(package);
    final uploaders = <Map<String, dynamic>>[];
    for (final id in uploaderIds) {
      final user = await metadataStore.lookupUserById(id);
      if (user != null) {
        uploaders.add({
          'userId': user.userId,
          'email': user.email,
          'displayName': user.displayName,
        });
      }
    }
    return _json({'uploaders': uploaders});
  }

  Future<Response> _addUploader(
    Request request,
    String package,
    String email,
  ) async {
    final actor = requireAuthUser(request);
    final canAdmin = await packageService.isPackageAdmin(package, actor.userId);
    if (!canAdmin) throw ForbiddenException.notUploader(package);

    final user = await metadataStore.lookupUserByEmail(email);
    if (user == null) throw NotFoundException.user(email);

    await metadataStore.addUploader(package, user.userId);
    return _json({'status': 'ok'});
  }

  Future<Response> _removeUploader(
    Request request,
    String package,
    String email,
  ) async {
    final actor = requireAuthUser(request);
    final canAdmin = await packageService.isPackageAdmin(package, actor.userId);
    if (!canAdmin) throw ForbiddenException.notUploader(package);

    final user = await metadataStore.lookupUserByEmail(email);
    if (user == null) throw NotFoundException.user(email);

    final uploaders = await metadataStore.listUploaders(package);
    if (uploaders.length <= 1) {
      throw const InvalidInputException('Cannot remove the last uploader.');
    }

    await metadataStore.removeUploader(package, user.userId);
    return _json({'status': 'ok'});
  }

  Future<Response> _getPublisher(Request request, String package) async {
    final pkg = await packageService.getPackage(package);
    return _json({'publisherId': pkg.publisherId});
  }

  /// Move a package between publishers, clear its publisher back to
  /// uploader-ownership, or assign a publisher to an uploader-owned
  /// package. A three-way authorization check:
  ///
  ///   - Actor must be package-admin on the *source* (server admin OR
  ///     uploader OR admin of the current publisher).
  ///   - If moving to a destination publisher, actor must also be an
  ///     admin of that destination (or a server admin). Otherwise a
  ///     publisher admin could dump packages into any other publisher's
  ///     namespace.
  ///   - Clearing the publisher reverts to uploader-owned. If the
  ///     existing uploader list is empty after release, we auto-add the
  ///     acting user so the package is never orphaned.
  Future<Response> _setPublisher(Request request, String package) async {
    final actor = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    // Source-side auth.
    final canAdmin = await packageService.isPackageAdmin(package, actor.userId);
    if (!canAdmin) throw ForbiddenException.notUploader(package);

    final pkg = await packageService.getPackage(package);
    final currentPublisherId = pkg.publisherId;

    // Normalise: an empty/absent publisherId means "clear".
    final rawNew = body['publisherId'];
    final newPublisherId = (rawNew is String && rawNew.trim().isNotEmpty)
        ? rawNew.trim()
        : null;

    if (newPublisherId == currentPublisherId) {
      return _json({'publisherId': currentPublisherId});
    }

    // Destination-side auth when moving INTO a publisher.
    if (newPublisherId != null) {
      final destExists = await metadataStore.lookupPublisher(newPublisherId);
      if (destExists == null) {
        throw NotFoundException.publisher(newPublisherId);
      }
      if (!actor.isAdmin) {
        final isDestAdmin = await metadataStore.isPublisherAdmin(
          newPublisherId,
          actor.userId,
        );
        if (!isDestAdmin) {
          throw const ForbiddenException(
            'You must be an admin of the destination publisher to transfer '
            'a package to it.',
          );
        }
      }
    }

    await metadataStore.updatePackage(
      package,
      PackageCompanion(name: package, publisherId: newPublisherId),
    );

    // If clearing, make sure the package isn't orphaned.
    if (newPublisherId == null) {
      final uploaders = await metadataStore.listUploaders(package);
      if (uploaders.isEmpty) {
        await metadataStore.addUploader(package, actor.userId);
      }
    }

    await metadataStore.appendAuditLog(
      AuditLogCompanion(
        id: packageService.generateId(),
        kind: AuditKind.publisherChanged,
        agentId: actor.userId,
        packageName: package,
        publisherId: newPublisherId,
        summary: _transferSummary(
          package,
          currentPublisherId,
          newPublisherId,
          actor.email,
        ),
      ),
    );

    return _json({'publisherId': newPublisherId});
  }

  static String _transferSummary(
    String pkg,
    String? from,
    String? to,
    String actorEmail,
  ) {
    if (from == null && to != null) {
      return 'Package $pkg assigned to publisher $to by $actorEmail.';
    }
    if (from != null && to == null) {
      return 'Package $pkg released from publisher $from back to uploaders '
          'by $actorEmail.';
    }
    return 'Package $pkg transferred from publisher $from to $to by '
        '$actorEmail.';
  }

  Future<Response> _getLikes(Request request, String package) async {
    final count = await metadataStore.likeCount(package);
    return _json({'package': package, 'likes': count});
  }

  Future<Response> _getPermissions(Request request, String package) async {
    final user = getAuthUser(request);
    if (user == null) return _json({'isAdmin': false});
    final canAdmin = await packageService.isPackageAdmin(package, user.userId);
    return _json({'isAdmin': canAdmin});
  }

  Future<Response> _getActivityLog(Request request, String package) async {
    final user = requireAuthUser(request);
    final canAdmin = await packageService.isPackageAdmin(package, user.userId);
    if (!canAdmin) throw ForbiddenException.notUploader(package);

    final before = request.url.queryParameters['before'];
    final records = await metadataStore.queryAuditLog(
      packageName: package,
      limit: 50,
      before: before != null ? DateTime.parse(before) : null,
    );

    // Resolve agent IDs to user info.
    final agentCache = <String, Map<String, String>>{};
    final entries = <Map<String, dynamic>>[];
    for (final r in records) {
      Map<String, String>? agent;
      if (r.agentId != null) {
        agent = agentCache[r.agentId!];
        if (agent == null) {
          final u = await metadataStore.lookupUserById(r.agentId!);
          agent = {
            'email': u?.email ?? 'unknown',
            'displayName': u?.displayName ?? 'Unknown',
          };
          agentCache[r.agentId!] = agent;
        }
      }
      entries.add({
        'id': r.id,
        'createdAt': r.createdAt.toIso8601String(),
        'kind': r.kind,
        'summary': r.summary,
        'version': r.version,
        'agent': ?agent,
      });
    }
    return _json({'entries': entries});
  }

  Future<Response> _deletePackage(Request request, String package) async {
    final user = requireAuthUser(request);
    final canAdmin = await packageService.isPackageAdmin(package, user.userId);
    if (!canAdmin) throw ForbiddenException.notUploader(package);

    // Deleting a package that public packages depend on is the same
    // breakage as making it private, with no undo at all. Same check,
    // and the caller has to say explicitly that they accept it.
    await _guardBreakage(
      request,
      package,
      action: 'Deleting $package',
    );

    final versions = await metadataStore.listVersions(package, scope: VisibilityScope.trustedInternal);
    for (final v in versions) {
      await blobStore.delete(package, v.version);
    }
    await metadataStore.deletePackage(package);

    // Same staleness fix as the admin delete path: dependents now point at
    // a row that is gone, and the recompute treats that as blocking.
    await metadataStore.recomputePublicResolvable(
      await metadataStore.packagesDependingOn({package}),
    );

    await metadataStore.appendAuditLog(
      AuditLogCompanion(
        id: packageService.generateId(),
        kind: AuditKind.packageDeleted,
        agentId: user.userId,
        packageName: package,
        summary: 'Package $package deleted by ${user.email}.',
      ),
    );

    return _json({'status': 'ok'});
  }

  Response _json(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );
}
