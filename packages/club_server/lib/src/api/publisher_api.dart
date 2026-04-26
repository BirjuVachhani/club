import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../middleware/auth_middleware.dart';

/// Publisher (organization) API handlers.
class PublisherApi {
  PublisherApi({required this.publisherService, required this.metadataStore});

  final PublisherService publisherService;
  final MetadataStore metadataStore;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/publishers', _list);
    router.post('/api/publishers', _create);
    // DNS-verified publisher creation (member+). Two-step:
    //   /verify/start → get TXT token
    //   /verify/complete → server probes DNS, creates publisher
    router.post('/api/publishers/verify/start', _verifyStart);
    router.post('/api/publishers/verify/complete', _verifyComplete);
    router.get('/api/publishers/<publisherId>', _get);
    router.put('/api/publishers/<publisherId>', _update);
    router.delete('/api/publishers/<publisherId>', _delete);
    router.get('/api/publishers/<publisherId>/packages', _publisherPackages);
    router.get('/api/publishers/<publisherId>/members', _listMembers);
    router.post('/api/publishers/<publisherId>/members', _addMemberByEmail);
    router.put('/api/publishers/<publisherId>/members/<userId>', _addMember);
    router.delete(
      '/api/publishers/<publisherId>/members/<userId>',
      _removeMember,
    );
    router.get(
      '/api/publishers/<publisherId>/activity-log',
      _publisherActivityLog,
    );
    return router;
  }

  /// Packages owned by a publisher. Public; used by the Packages tab on
  /// publisher detail pages.
  Future<Response> _publisherPackages(
    Request request,
    String publisherId,
  ) async {
    final page = request.url.queryParameters['page'];
    final includeUnlisted =
        request.url.queryParameters['includeUnlisted'] == '1';

    final result = await metadataStore.listPackagesForPublisher(
      publisherId,
      limit: 50,
      pageToken: page,
      includeUnlisted: includeUnlisted,
    );

    // Enrich with pubspec-derived fields so the shared PackageCard
    // component (sdk/platform badges, description, repo host) renders
    // the same way it does on search and /my-packages.
    final enriched = <Map<String, dynamic>>[];
    for (final p in result.items) {
      enriched.add(await _packageCardJson(p));
    }

    return Response.ok(
      jsonEncode({
        'packages': enriched,
        'totalCount': result.totalCount,
        'nextPageToken': result.nextPageToken,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Map<String, dynamic>> _packageCardJson(Package p) async {
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

  /// Public list of all publishers. Used by the browse page and by admin
  /// publisher-picker dropdowns.
  Future<Response> _list(Request request) async {
    final publishers = await metadataStore.listPublishers();
    return Response.ok(
      jsonEncode({
        'publishers': publishers.map(_publisherJson).toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Convenience wrapper that resolves an email to a userId before adding
  /// a member. Publisher admin UIs collect email, not opaque userId.
  Future<Response> _addMemberByEmail(
    Request request,
    String publisherId,
  ) async {
    final actingUser = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String? ?? '').trim();
    final role = body['role'] as String? ?? PublisherRole.member;

    if (email.isEmpty) {
      throw const InvalidInputException('email is required.');
    }

    final target = await metadataStore.lookupUserByEmail(email);
    if (target == null) throw NotFoundException.user(email);

    await publisherService.addMember(
      publisherId,
      target.userId,
      role: role,
      actingUserId: actingUser.userId,
    );

    return Response.ok(
      jsonEncode({
        'status': 'ok',
        'userId': target.userId,
        'email': target.email,
        'displayName': target.displayName,
        'role': role,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Activity log for a publisher. Visible to members only — the server
  /// enforces this via the member check below.
  Future<Response> _publisherActivityLog(
    Request request,
    String publisherId,
  ) async {
    final user = requireAuthUser(request);

    final isMember = await metadataStore.isPublisherMember(
      publisherId,
      user.userId,
    );
    if (!isMember && !user.isAdmin) {
      throw ForbiddenException.notAdmin();
    }

    final beforeStr = request.url.queryParameters['before'];
    final before = beforeStr != null ? DateTime.tryParse(beforeStr) : null;

    final records = await metadataStore.queryAuditLog(
      publisherId: publisherId,
      limit: 50,
      before: before,
    );

    // Resolve agent IDs to user info for display.
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
        if (r.packageName != null) 'package': r.packageName,
        if (r.version != null) 'version': r.version,
        'agent': ?agent,
      });
    }

    return Response.ok(
      jsonEncode({'entries': entries}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Create an internal (unverified) publisher. Admin-only because it
  /// bypasses domain proof. Optional `initialAdminEmail` hands the new
  /// publisher to a specific user as its first admin — convenient when
  /// an admin is setting a publisher up on behalf of a team.
  Future<Response> _create(Request request) async {
    final user = requireAuthUser(request);
    if (!Permissions.canCreateInternalPublisher(user.role)) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    // Resolve initial admin (optional) by email.
    String? initialAdminUserId;
    final initialAdminEmail = (body['initialAdminEmail'] as String? ?? '')
        .trim();
    if (initialAdminEmail.isNotEmpty) {
      final target = await metadataStore.lookupUserByEmail(initialAdminEmail);
      if (target == null) {
        throw NotFoundException.user(initialAdminEmail);
      }
      initialAdminUserId = target.userId;
    }

    final pub = await publisherService.createInternalPublisher(
      id: body['id'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      description: body['description'] as String?,
      websiteUrl: body['websiteUrl'] as String?,
      contactEmail: body['contactEmail'] as String?,
      createdByUserId: user.userId,
      initialAdminUserId: initialAdminUserId,
    );

    return Response(
      201,
      body: jsonEncode(_publisherJson(pub)),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Begin a DNS-based verification. Returns the token and the exact
  /// TXT host/value the user needs to set up.
  Future<Response> _verifyStart(Request request) async {
    final user = requireAuthUser(request);
    if (!Permissions.canVerifyPublisher(user.role)) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final result = await publisherService.startVerification(
      userId: user.userId,
      domain: body['domain'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
    );

    return Response.ok(
      jsonEncode({
        'domain': (body['domain'] as String? ?? '').trim().toLowerCase(),
        'host': result.host,
        'value': result.value,
        'token': result.token,
        'expiresAt': result.expiresAt.toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Complete a verification. On success the publisher exists and the
  /// acting user is its first admin.
  Future<Response> _verifyComplete(Request request) async {
    final user = requireAuthUser(request);
    if (!Permissions.canVerifyPublisher(user.role)) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final pub = await publisherService.completeVerification(
      userId: user.userId,
      domain: body['domain'] as String? ?? '',
      displayName: body['displayName'] as String? ?? '',
      description: body['description'] as String?,
      websiteUrl: body['websiteUrl'] as String?,
      contactEmail: body['contactEmail'] as String?,
    );

    return Response(
      201,
      body: jsonEncode(_publisherJson(pub)),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Delete a publisher. The service refuses to delete any publisher
  /// that still owns packages — the caller must transfer or clear those
  /// first. Allowed for publisher admins OR server admins.
  Future<Response> _delete(Request request, String publisherId) async {
    final user = requireAuthUser(request);

    await publisherService.deletePublisher(
      publisherId: publisherId,
      actingUserId: user.userId,
      actorIsServerAdmin: user.isAdmin,
    );

    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _get(Request request, String publisherId) async {
    final pub = await publisherService.getPublisher(publisherId);

    // Include the caller's role inline so the UI can gate admin controls
    // on a single round-trip instead of also hitting /api/account/publishers.
    final caller = getAuthUser(request);
    String? callerRole;
    if (caller != null) {
      final members = await metadataStore.listPublisherMembers(publisherId);
      final mine = members.where((m) => m.userId == caller.userId).toList();
      if (mine.isNotEmpty) callerRole = mine.first.role;
    }

    final body = _publisherJson(pub);
    if (callerRole != null) body['callerRole'] = callerRole;
    return Response.ok(
      jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _update(Request request, String publisherId) async {
    final user = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    final pub = await publisherService.updatePublisher(
      publisherId,
      displayName: body['displayName'] as String?,
      description: body['description'] as String?,
      websiteUrl: body['websiteUrl'] as String?,
      contactEmail: body['contactEmail'] as String?,
      actingUserId: user.userId,
    );

    return Response.ok(
      jsonEncode(_publisherJson(pub)),
      headers: {'content-type': 'application/json'},
    );
  }

  /// Members of a publisher. Visible only to other members or server
  /// admins — the list includes emails and display names, so leaking it
  /// publicly would enumerate user accounts.
  Future<Response> _listMembers(Request request, String publisherId) async {
    final caller = requireAuthUser(request);
    final isMember = await metadataStore.isPublisherMember(
      publisherId,
      caller.userId,
    );
    if (!isMember && !caller.isAdmin) {
      throw ForbiddenException.notAdmin();
    }

    final members = await publisherService.listMembers(publisherId);
    final memberList = <Map<String, dynamic>>[];

    for (final m in members) {
      final user = await metadataStore.lookupUserById(m.userId);
      memberList.add({
        'userId': m.userId,
        'email': user?.email,
        'displayName': user?.displayName,
        'role': m.role,
      });
    }

    return Response.ok(
      jsonEncode({'members': memberList}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _addMember(
    Request request,
    String publisherId,
    String userId,
  ) async {
    final actingUser = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final role = body['role'] as String? ?? PublisherRole.member;

    await publisherService.addMember(
      publisherId,
      userId,
      role: role,
      actingUserId: actingUser.userId,
    );

    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _removeMember(
    Request request,
    String publisherId,
    String userId,
  ) async {
    final actingUser = requireAuthUser(request);
    await publisherService.removeMember(
      publisherId,
      userId,
      actingUserId: actingUser.userId,
    );

    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  Map<String, dynamic> _publisherJson(Publisher pub) => {
    'publisherId': pub.id,
    'displayName': pub.displayName,
    'description': pub.description,
    'websiteUrl': pub.websiteUrl,
    'contactEmail': pub.contactEmail,
    'verified': pub.verified,
    // Convenience: for verified publishers the id is the domain. Exposing
    // it as a separate field lets the UI avoid having to sniff for dots.
    if (pub.verified) 'domain': pub.id,
    'createdAt': pub.createdAt.toIso8601String(),
  };
}
