import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:club_core/club_core.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../config/app_config.dart';
import '../middleware/auth_middleware.dart';

/// Server admin API handlers.
///
/// Every mutation here goes through the [Permissions] matrix rather than
/// inline role inspection, and emits an audit log entry when it changes
/// server state.
class AdminApi {
  AdminApi({
    required this.authService,
    required this.metadataStore,
    required this.blobStore,
    required this.searchIndex,
    required this.serverUrl,
    required this.config,
    required this.startedAt,
  });

  final AuthService authService;
  final MetadataStore metadataStore;
  final BlobStore blobStore;
  final SearchIndex searchIndex;

  /// Public base URL, used to produce full invite links.
  final Uri serverUrl;

  final AppConfig config;
  final DateTime startedAt;

  DecodedRouter get router {
    final router = DecodedRouter();
    router.get('/api/admin/stats', _getStats);
    router.get('/api/admin/users', _listUsers);
    router.post('/api/admin/users', _createUser);
    router.get('/api/admin/users/<userId>', _getUser);
    router.put('/api/admin/users/<userId>', _updateUser);
    router.delete('/api/admin/users/<userId>', _deleteUser);
    router.post('/api/admin/users/<userId>/reset-password', _resetPassword);
    router.post('/api/admin/transfer-ownership', _transferOwnership);

    router.get('/api/admin/packages', _listPackages);
    router.delete('/api/admin/packages/<package>', _deletePackage);
    router.delete(
      '/api/admin/packages/<package>/versions/<version>',
      _deleteVersion,
    );

    router.get('/api/admin/integrity', _getIntegrity);
    return router;
  }

  // ── Integrity check ──────────────────────────────────────────

  /// Flag DB package_versions rows whose tarball is missing from the
  /// blob store. Drives an admin-facing popup so the operator can
  /// choose to delete the stranded entry. The DB is the source of
  /// truth — orphan tarballs with no DB row are not reported here.
  Future<Response> _getIntegrity(Request request) async {
    requireRole(request, UserRole.admin);

    final missing = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final page = await metadataStore.listPackages(
        limit: 100,
        pageToken: pageToken,
      );
      for (final pkg in page.items) {
        final versions = await metadataStore.listVersions(pkg.name);
        // Probe existence in parallel per-package. `exists` is cheap on a
        // local filesystem but can be an HTTP HEAD per call on S3/GCS —
        // fanning out keeps the handler from serialising hundreds of
        // round-trips end-to-end.
        final probes = await Future.wait(
          versions.map(
            (v) async =>
                (v: v, found: await blobStore.exists(pkg.name, v.version)),
          ),
        );
        for (final p in probes) {
          if (p.found) continue;
          missing.add({
            'package': pkg.name,
            'version': p.v.version,
            'publishedAt': p.v.publishedAt.toIso8601String(),
          });
        }
      }
      pageToken = page.nextPageToken;
    } while (pageToken != null);

    return _jsonResponse({'missingVersions': missing});
  }

  // ── Stats ────────────────────────────────────────────────────

  Future<Response> _getStats(Request request) async {
    requireRole(request, UserRole.admin);

    final now = DateTime.now().toUtc();
    final counts = await metadataStore.counts();

    // Disk usage: tarballs
    final bool blobIsLocal = config.blobBackend == BlobBackend.filesystem;
    final int? tarballBytes = blobIsLocal
        ? await _directorySize(config.blobPath)
        : null;

    // Disk usage: dartdoc
    final int? docsBytes = await _directorySize(config.dartdocPath);

    // Disk usage: database
    int? dbBytes;
    if (config.dbBackend == DbBackend.sqlite) {
      dbBytes = await _sqliteDbSize(config.sqlitePath);
    }

    // Total = sum of all available local sizes
    final totalBytes = (tarballBytes ?? 0) + (docsBytes ?? 0) + (dbBytes ?? 0);

    return _jsonResponse({
      'uptime': {
        'startedAt': startedAt.toIso8601String(),
        'uptimeSeconds': now.difference(startedAt).inSeconds,
      },
      'counts': {
        'packages': counts.packages,
        'versions': counts.versions,
        'users': counts.users,
      },
      'disk': {
        'tarballs': {
          'bytes': tarballBytes,
          'available': blobIsLocal,
        },
        'docs': {
          'bytes': docsBytes,
          'available': docsBytes != null,
        },
        'database': {
          'bytes': dbBytes,
          'available': dbBytes != null,
        },
        'total': {
          'bytes': totalBytes,
          'available': blobIsLocal || docsBytes != null || dbBytes != null,
        },
      },
      'backends': {
        'db': config.dbBackend.name,
        'blob': config.blobBackend.name,
      },
    });
  }

  /// Recursively sum file sizes in a directory. Returns null if the
  /// directory does not exist or is unreadable.
  static Future<int?> _directorySize(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return null;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on FileSystemException {
            // Skip unreadable files.
          }
        }
      }
    } on FileSystemException {
      return null;
    }
    return total;
  }

  /// Sum the sizes of the SQLite database file and its WAL/SHM sidecars.
  static Future<int?> _sqliteDbSize(String dbPath) async {
    var total = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      try {
        if (await file.exists()) {
          total += await file.length();
        }
      } on FileSystemException {
        // Skip unreadable sidecar files.
      }
    }
    return total > 0 ? total : null;
  }

  // ── User management ──────────────────────────────────────────

  Future<Response> _listUsers(Request request) async {
    requireRole(request, UserRole.admin);
    final email = request.url.queryParameters['email'];
    final page = request.url.queryParameters['page'];

    final result = await metadataStore.listUsers(
      limit: 50,
      pageToken: page,
      emailFilter: email,
    );

    return Response.ok(
      jsonEncode({
        'users': result.items.map(_userToJson).toList(),
        'totalCount': result.totalCount,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _getUser(Request request, String userId) async {
    requireRole(request, UserRole.admin);
    final user = await metadataStore.lookupUserById(userId);
    if (user == null) throw NotFoundException.user(userId);
    return _jsonResponse(_userToJson(user));
  }

  /// Create a new user. Two modes:
  ///
  ///   { "mode": "password", ... }  → server generates a random password
  ///                                   and returns it once
  ///   { "mode": "invite",   ... }  → server generates a single-use invite
  ///                                   link and returns it once
  ///
  /// Both paths set [User.mustChangePassword] = true for "password" mode
  /// (so the user is forced to reset on first login) and for "invite"
  /// mode the user sets their own password when accepting the link.
  Future<Response> _createUser(Request request) async {
    final actor = requireRole(request, UserRole.admin);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    final email = (body['email'] as String? ?? '').trim();
    final displayName = (body['displayName'] as String? ?? '').trim();
    final roleName = body['role'] as String? ?? UserRole.viewer.name;
    final mode = body['mode'] as String? ?? 'password';

    if (email.isEmpty) {
      throw const InvalidInputException('email is required.');
    }
    if (displayName.isEmpty) {
      throw const InvalidInputException('displayName is required.');
    }

    final role = UserRole.tryFromString(roleName);
    if (role == null) {
      throw InvalidInputException('Unknown role: $roleName');
    }
    if (!Permissions.canAssignRole(actor: actor.role, newRole: role)) {
      throw ForbiddenException.notAdmin();
    }

    final String? plainPassword;
    final bool mustChangePassword;
    if (mode == 'password') {
      plainPassword = _generateRandomPassword();
      mustChangePassword = true;
    } else if (mode == 'invite') {
      // Create the user with a random password they'll never use — they
      // set their own when they accept the invite. The invite flow below
      // overwrites the password.
      plainPassword = _generateRandomPassword();
      mustChangePassword = false;
    } else {
      throw InvalidInputException('Unknown mode: $mode');
    }

    final user = await authService.createUser(
      email: email,
      password: plainPassword,
      displayName: displayName,
      role: role,
      mustChangePassword: mustChangePassword,
    );

    final out = <String, Object?>{
      ..._userToJson(user),
      'mode': mode,
    };

    if (mode == 'password') {
      // Shown once — admin copies it out-of-band to the new user.
      out['generatedPassword'] = plainPassword;
    } else {
      // Create a single-use invite token, 7-day default expiry.
      final rawToken = _generateRandomToken();
      final tokenHash = sha256.convert(utf8.encode(rawToken)).toString();
      final expiresIn = (body['expiresInHours'] as int?) ?? 24 * 7;
      await metadataStore.createInvite(
        UserInviteCompanion(
          inviteId: _generateId(),
          userId: user.userId,
          tokenHash: tokenHash,
          expiresAt: DateTime.now().toUtc().add(Duration(hours: expiresIn)),
          createdBy: actor.userId,
        ),
      );
      out['inviteUrl'] = serverUrl.resolve('/invite/$rawToken').toString();
      out['inviteExpiresInHours'] = expiresIn;
    }

    return Response(
      201,
      body: jsonEncode(out),
      headers: {
        'content-type': 'application/json',
      },
    );
  }

  /// Update role / display name / active state on a user. Password is not
  /// updatable here — use `/reset-password` instead.
  Future<Response> _updateUser(Request request, String userId) async {
    final actor = requireRole(request, UserRole.admin);
    final target = await metadataStore.lookupUserById(userId);
    if (target == null) throw NotFoundException.user(userId);

    if (!Permissions.canModifyUser(
      actor: actor.role,
      actorId: actor.userId,
      target: target.role,
      targetId: target.userId,
    )) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;

    // Determine the new role (if any) and guard it.
    UserRole newRole = target.role;
    if (body.containsKey('role')) {
      final parsed = UserRole.tryFromString(body['role'] as String?);
      if (parsed == null) {
        throw InvalidInputException('Unknown role: ${body['role']}');
      }
      if (!Permissions.canAssignRole(actor: actor.role, newRole: parsed)) {
        throw ForbiddenException.notAdmin();
      }
      newRole = parsed;
    }

    final companion = UserCompanion(
      userId: userId,
      email: target.email,
      passwordHash: '', // sentinel: preserve existing
      displayName: body['displayName'] as String? ?? target.displayName,
      isActive: body['isActive'] as bool? ?? target.isActive,
      role: newRole,
      mustChangePassword: target.mustChangePassword,
    );

    final updated = await metadataStore.updateUser(userId, companion);

    await _audit(
      kind: AuditKind.userUpdated,
      actorId: actor.userId,
      summary:
          'User ${updated.email} updated by ${actor.email} '
          '(role=${updated.role.name}, active=${updated.isActive}).',
    );

    return _jsonResponse(_userToJson(updated));
  }

  Future<Response> _deleteUser(Request request, String userId) async {
    final actor = requireRole(request, UserRole.admin);
    final target = await metadataStore.lookupUserById(userId);
    if (target == null) throw NotFoundException.user(userId);

    if (!Permissions.canModifyUser(
      actor: actor.role,
      actorId: actor.userId,
      target: target.role,
      targetId: target.userId,
    )) {
      throw ForbiddenException.notAdmin();
    }

    await metadataStore.deleteUser(userId);
    await _audit(
      kind: AuditKind.userDisabled,
      actorId: actor.userId,
      summary: 'User ${target.email} deleted by ${actor.email}.',
    );
    return _jsonResponse({'status': 'ok'});
  }

  /// Reset a user's password. Admin can pick a new password themselves or
  /// ask the server to generate one. Either way, the user is forced to
  /// pick a new one on their next login (`mustChangePassword = true`).
  Future<Response> _resetPassword(Request request, String userId) async {
    final actor = requireRole(request, UserRole.admin);
    final target = await metadataStore.lookupUserById(userId);
    if (target == null) throw NotFoundException.user(userId);

    if (!Permissions.canModifyUser(
      actor: actor.role,
      actorId: actor.userId,
      target: target.role,
      targetId: target.userId,
    )) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final explicit = (body['password'] as String?)?.trim();
    final plainPassword = (explicit == null || explicit.isEmpty)
        ? _generateRandomPassword()
        : explicit;

    if (plainPassword.length < 8) {
      throw const InvalidInputException(
        'Password must be at least 8 characters.',
      );
    }

    // Direct store call — admin path does not need the old password.
    final hashed = await authService.hashPassword(plainPassword);
    await metadataStore.updateUser(
      userId,
      UserCompanion(
        userId: userId,
        email: target.email,
        passwordHash: hashed,
        displayName: target.displayName,
        role: target.role,
        isActive: target.isActive,
        mustChangePassword: true,
      ),
    );

    await _audit(
      kind: AuditKind.userUpdated,
      actorId: actor.userId,
      summary:
          'Password reset for ${target.email} by ${actor.email}. Must change on next login.',
    );

    return _jsonResponse({
      'userId': userId,
      'generatedPassword': plainPassword,
      'mustChangePassword': true,
    });
  }

  /// Atomically transfer the owner role. Owner-only. Previous owner is
  /// demoted to admin in the same transaction so the server is never
  /// without an owner.
  Future<Response> _transferOwnership(Request request) async {
    final actor = requireRole(request, UserRole.owner);
    if (!Permissions.canTransferOwnership(actor.role)) {
      throw ForbiddenException.notAdmin();
    }

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final targetEmail = (body['email'] as String? ?? '').trim();
    if (targetEmail.isEmpty) {
      throw const InvalidInputException('email is required.');
    }
    final target = await metadataStore.lookupUserByEmail(targetEmail);
    if (target == null) throw NotFoundException.user(targetEmail);
    if (target.userId == actor.userId) {
      throw const InvalidInputException(
        'You are already the owner of this server.',
      );
    }

    // Transaction so there's never two owners or zero.
    await metadataStore.transaction((tx) async {
      await tx.updateUser(
        actor.userId,
        UserCompanion(
          userId: actor.userId,
          email: actor.email,
          passwordHash: '', // preserve
          displayName: actor.displayName,
          role: UserRole.admin,
          isActive: true,
        ),
      );
      await tx.updateUser(
        target.userId,
        UserCompanion(
          userId: target.userId,
          email: target.email,
          passwordHash: '',
          displayName: target.displayName,
          role: UserRole.owner,
          isActive: target.isActive,
          mustChangePassword: target.mustChangePassword,
        ),
      );
    });

    await _audit(
      kind: AuditKind.userUpdated,
      actorId: actor.userId,
      summary: 'Ownership transferred from ${actor.email} to ${target.email}.',
    );

    return _jsonResponse({'status': 'ok'});
  }

  // ── Package moderation ───────────────────────────────────────

  /// Admin-facing paginated package list with extra metadata the public
  /// `/api/packages` doesn't carry — version count, total size, uploader
  /// count. Used by the admin packages page. Supports `?q=` substring
  /// match on name.
  Future<Response> _listPackages(Request request) async {
    requireRole(request, UserRole.admin);
    final query = request.url.queryParameters['q'];
    final page = request.url.queryParameters['page'];

    final result = await metadataStore.listPackages(
      limit: 50,
      pageToken: page,
      query: query,
    );

    final rows = <Map<String, dynamic>>[];
    for (final p in result.items) {
      final versions = await metadataStore.listVersions(p.name);
      final totalBytes = versions.fold<int>(
        0,
        (sum, v) => sum + v.archiveSizeBytes,
      );
      rows.add({
        'name': p.name,
        'publisherId': p.publisherId,
        'latestVersion': p.latestVersion,
        'versionCount': versions.length,
        'totalBytes': totalBytes,
        'likesCount': p.likesCount,
        'isDiscontinued': p.isDiscontinued,
        'isUnlisted': p.isUnlisted,
        'updatedAt': p.updatedAt.toIso8601String(),
      });
    }

    return _jsonResponse({
      'packages': rows,
      'totalCount': result.totalCount,
      'nextPageToken': result.nextPageToken,
    });
  }

  Future<Response> _deletePackage(Request request, String package) async {
    final actor = requireRole(request, UserRole.admin);

    final versions = await metadataStore.listVersions(package);
    for (final v in versions) {
      await blobStore.delete(package, v.version);
    }

    await metadataStore.deletePackage(package);
    await searchIndex.removePackage(package);

    await _audit(
      kind: AuditKind.packageDeleted,
      actorId: actor.userId,
      packageName: package,
      summary: 'Package $package deleted by ${actor.email}.',
    );

    return _jsonResponse({'status': 'ok'});
  }

  Future<Response> _deleteVersion(
    Request request,
    String package,
    String version,
  ) async {
    final actor = requireRole(request, UserRole.admin);

    await blobStore.delete(package, version);
    await metadataStore.deleteVersion(package, version);

    // Keep the FTS5 index in sync. metadataStore.deleteVersion has
    // already recomputed packages.latest_version: if it's null, no
    // versions remain and the package is gone from the search surface;
    // otherwise re-index with the new latest's pubspec/readme so search
    // hits don't surface stale content from the version we just deleted.
    final pkg = await metadataStore.lookupPackage(package);
    final newLatest = pkg?.latestVersion;
    if (newLatest == null) {
      await searchIndex.removePackage(package);
    } else {
      final pv = await metadataStore.lookupVersion(package, newLatest);
      if (pv != null) {
        await searchIndex.indexPackage(_indexDocFor(pv));
      }
    }

    await _audit(
      kind: AuditKind.packageDeleted,
      actorId: actor.userId,
      packageName: package,
      version: version,
      summary: 'Package $package@$version deleted by ${actor.email}.',
    );

    return _jsonResponse({'status': 'ok'});
  }

  IndexDocument _indexDocFor(PackageVersion pv) {
    final pubspec = jsonDecode(pv.pubspecJson) as Map<String, dynamic>;
    final description = pubspec['description'] as String? ?? '';
    final rawTopics = pubspec['topics'];
    final topics = rawTopics is List
        ? rawTopics
              .whereType<String>()
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty)
              .toList()
        : const <String>[];
    final readme = pv.readmeContent;
    return IndexDocument(
      package: pv.packageName,
      latestVersion: pv.version,
      description: description,
      readme: readme?.substring(0, readme.length.clamp(0, 2048)),
      topics: topics,
      publishedAt: pv.publishedAt,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────

  Future<void> _audit({
    required String kind,
    required String actorId,
    String? packageName,
    String? version,
    required String summary,
  }) async {
    await metadataStore.appendAuditLog(
      AuditLogCompanion(
        id: _generateId(),
        kind: kind,
        agentId: actorId,
        packageName: packageName,
        version: version,
        summary: summary,
      ),
    );
  }

  Map<String, Object?> _userToJson(User u) => {
    'userId': u.userId,
    'email': u.email,
    'displayName': u.displayName,
    'role': u.role.name,
    'isAdmin': u.isAdmin, // legacy
    'isActive': u.isActive,
    'mustChangePassword': u.mustChangePassword,
    'avatarUrl': u.hasAvatar ? '/api/users/${u.userId}/avatar' : null,
    'createdAt': u.createdAt.toIso8601String(),
  };

  Response _jsonResponse(Object data) => Response.ok(
    jsonEncode(data),
    headers: {'content-type': 'application/json'},
  );

  // ── ID / secret generators ───────────────────────────────────

  /// UUID-ish identifier. Uses `Random.secure` so it's safe for database
  /// primary keys and audit log IDs.
  static String _generateId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 16-char random password: letters + digits. High entropy, easy to
  /// eyeball in the UI.
  static String _generateRandomPassword() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    final r = Random.secure();
    return List.generate(
      16,
      (_) => alphabet[r.nextInt(alphabet.length)],
    ).join();
  }

  /// Cryptographically strong random token for invite URLs.
  static String _generateRandomToken() {
    final r = Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
