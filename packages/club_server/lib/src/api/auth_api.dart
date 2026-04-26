import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:club_core/club_core.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';

import '../http/decoded_router.dart';
import '../auth/cookies.dart';
import '../auth/geo_locator.dart';
import '../auth/token_scopes.dart';
import '../middleware/auth_middleware.dart';

/// Authentication, session, and API-key endpoints.
///
/// The API is split across three user-facing concepts:
///
///   - `/api/auth/*`      password login, logout, profile, change-password, /me
///   - `/api/auth/sessions/*`  the user's active web sessions (kind=session)
///   - `/api/auth/keys/*`      the user's personal access tokens (kind=pat)
///
/// The web UI authenticates via an HttpOnly session cookie; the CLI /
/// programmatic clients use `Authorization: Bearer <club_pat_...>`.
class AuthApi {
  AuthApi({
    required this.authService,
    required this.metadataStore,
    required this.geoLocator,
    required this.signupEnabled,
    required this.trustProxy,
  });

  final AuthService authService;
  final MetadataStore metadataStore;

  /// Resolves the client IP to a point-in-time location at login. Failures
  /// are swallowed by the locator itself — login must never block on it.
  final GeoLocator geoLocator;

  final bool signupEnabled;

  /// Matches [AppConfig.trustProxy]. Gates whether `X-Forwarded-Proto`
  /// and `X-Forwarded-For` are honored when deciding cookie `Secure` or
  /// recording client IPs — see [cookies.dart].
  final bool trustProxy;

  DecodedRouter get router {
    final router = DecodedRouter();

    router.post('/api/auth/login', _login);
    router.post('/api/auth/logout', _logout);
    router.get('/api/auth/me', _me);
    router.post('/api/auth/signup', _signup);
    router.post('/api/auth/change-password', _changePassword);
    router.patch('/api/auth/profile', _updateProfile);
    router.post('/api/auth/avatar', _uploadAvatar);
    router.delete('/api/auth/avatar', _deleteAvatar);
    router.get('/api/users/<userId>/avatar', _serveAvatar);

    // Personal access tokens (aka API keys). Shown on Settings → API Keys.
    router.post('/api/auth/keys', _createKey);
    router.get('/api/auth/keys', _listKeys);
    router.delete('/api/auth/keys/<tokenId>', _revokeKey);

    // Active browser sessions. Shown on Settings → Sessions.
    router.get('/api/auth/sessions', _listSessions);
    router.delete('/api/auth/sessions/<tokenId>', _revokeSession);
    router.post('/api/auth/sessions/revoke-others', _revokeOtherSessions);

    // Invite-link flow.
    router.get('/api/invites/<token>', _lookupInvite);
    router.post('/api/invites/<token>/accept', _acceptInvite);

    return router;
  }

  // ── Login / Logout / Me ──────────────────────────────────────

  Future<Response> _login(Request request) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String? ?? '').trim();
    final password = body['password'] as String? ?? '';

    if (email.isEmpty || password.isEmpty) {
      throw const InvalidInputException('Email and password are required.');
    }

    final user = await authService.authenticatePassword(email, password);

    final clientIp = _clientIp(request);
    final location = clientIp == null ? null : await geoLocator.lookup(clientIp);

    final session = await authService.createSession(
      userId: user.userId,
      scopes: scopesForRole(user.role),
      userAgent: request.headers[HttpHeaders.userAgentHeader],
      clientIp: clientIp,
      clientCity: location?.city,
      clientRegion: location?.region,
      clientCountry: location?.country,
      clientCountryCode: location?.countryCode,
    );

    final csrf = generateCsrfToken();
    final secure = isHttpsRequest(request, trustProxy: trustProxy);

    // Pass Set-Cookie as a List<String> so shelf_io emits it as two
    // distinct headers. Comma-joining violates RFC 7230 — any future
    // cookie attribute that contains a comma (e.g. an Expires date)
    // would mis-parse on receipt.
    return Response.ok(
      jsonEncode(_userJson(user)),
      headers: <String, Object>{
        'content-type': 'application/json',
        'set-cookie': <String>[
          buildSessionCookie(
            rawSecret: session.rawSecret,
            maxAge: SessionLifetime.sliding,
            secure: secure,
          ),
          buildCsrfCookie(
            value: csrf,
            maxAge: SessionLifetime.sliding,
            secure: secure,
          ),
        ],
      },
    );
  }

  Future<Response> _logout(Request request) async {
    final auth = getAuthUser(request);
    if (auth != null && auth.tokenKind == ApiTokenKind.session) {
      // Revoke the exact session this request rode in on. Doesn't touch
      // the user's other sessions or API keys.
      await authService.revokeToken(
        tokenId: auth.tokenId,
        actingUserId: auth.userId,
      );
    }

    final secure = isHttpsRequest(request, trustProxy: trustProxy);
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: <String, Object>{
        'content-type': 'application/json',
        'set-cookie': buildClearedAuthCookies(secure: secure),
      },
    );
  }

  /// Bootstrap endpoint for the SPA. Returns the current user if the
  /// session cookie is valid, 401 otherwise. No side effects.
  Future<Response> _me(Request request) async {
    final auth = getAuthUser(request);
    if (auth == null) {
      return Response(
        401,
        body: jsonEncode({
          'error': {
            'code': 'MissingAuthentication',
            'message': 'Not signed in.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    final user = await metadataStore.lookupUserById(auth.userId);
    if (user == null) {
      return Response(
        401,
        body: jsonEncode({
          'error': {
            'code': 'MissingAuthentication',
            'message': 'Not signed in.',
          },
        }),
        headers: {'content-type': 'application/json'},
      );
    }
    return Response.ok(
      jsonEncode(_userJson(user)),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── Signup ────────────────────────────────────────────────────

  Future<Response> _signup(Request request) async {
    if (!signupEnabled) {
      throw const ForbiddenException(
        'Self-signup is disabled on this server.',
      );
    }
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String? ?? '').trim();
    final password = body['password'] as String? ?? '';
    final displayName = (body['displayName'] as String? ?? '').trim();

    if (email.isEmpty || password.isEmpty || displayName.isEmpty) {
      throw const InvalidInputException(
        'email, password, and displayName are required.',
      );
    }
    if (password.length < 8) {
      throw const InvalidInputException(
        'Password must be at least 8 characters.',
      );
    }
    if (password.length > AuthService.maxPasswordLength) {
      throw InvalidInputException(
        'Password must be at most ${AuthService.maxPasswordLength} characters.',
      );
    }

    // Intentionally opaque to the caller: whether the email already existed
    // or was fresh, the response is identical. Legit signups succeed; a
    // probe against an existing email returns the same shape, and the
    // attacker's follow-up /login call fails naturally (rate-limited) on
    // the wrong password. This removes signup as a user-enumeration oracle.
    //
    // We still create the user on the happy path; we just swallow the
    // conflict silently. No session is issued here — the client follows
    // up with /api/auth/login, which is the single funnel for session
    // creation.
    try {
      await authService.createUser(
        email: email,
        password: password,
        displayName: displayName,
        role: UserRole.member,
      );
    } on ConflictException {
      // Drop — responding differently here would reveal account existence.
    }

    return Response(
      202,
      body: jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── Invite accept ────────────────────────────────────────────

  Future<Response> _lookupInvite(Request request, String token) async {
    final invite = await _lookupValidInvite(token);
    final user = await metadataStore.lookupUserById(invite.userId);
    if (user == null) {
      throw const InvalidInputException('Invite target user no longer exists.');
    }
    return Response.ok(
      jsonEncode({
        'email': user.email,
        'displayName': user.displayName,
        'expiresAt': invite.expiresAt.toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _acceptInvite(Request request, String token) async {
    final invite = await _lookupValidInvite(token);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final newPassword = body['password'] as String? ?? '';
    if (newPassword.length < 8) {
      throw const InvalidInputException(
        'Password must be at least 8 characters.',
      );
    }
    if (newPassword.length > AuthService.maxPasswordLength) {
      throw InvalidInputException(
        'Password must be at most ${AuthService.maxPasswordLength} characters.',
      );
    }

    final user = await metadataStore.lookupUserById(invite.userId);
    if (user == null) {
      throw const InvalidInputException('Invite target user no longer exists.');
    }

    final newHash = await authService.hashPassword(newPassword);
    await metadataStore.updateUser(
      user.userId,
      UserCompanion(
        userId: user.userId,
        email: user.email,
        passwordHash: newHash,
        displayName: user.displayName,
        role: user.role,
        isActive: true,
        mustChangePassword: false,
      ),
    );

    await metadataStore.markInviteUsed(invite.inviteId);

    return Response.ok(
      jsonEncode({
        'userId': user.userId,
        'email': user.email,
        'displayName': user.displayName,
        'role': user.role.name,
        'mustChangePassword': false,
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<UserInvite> _lookupValidInvite(String rawToken) async {
    final hash = sha256.convert(utf8.encode(rawToken)).toString();
    final invite = await metadataStore.lookupInviteByHash(hash);
    if (invite == null) {
      throw const NotFoundException('Invite not found or has expired.');
    }
    if (!invite.isValid) {
      throw const InvalidInputException(
        'This invite link has already been used or has expired.',
      );
    }
    return invite;
  }

  // ── Profile / password ───────────────────────────────────────

  Future<Response> _updateProfile(Request request) async {
    final auth = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final displayName = (body['displayName'] as String? ?? '').trim();

    if (displayName.isEmpty) {
      throw const InvalidInputException('displayName is required.');
    }

    final current = await metadataStore.lookupUserById(auth.userId);
    if (current == null) {
      throw NotFoundException.user(auth.userId);
    }

    final updated = await metadataStore.updateUser(
      current.userId,
      UserCompanion(
        userId: current.userId,
        email: current.email,
        passwordHash: '', // sentinel: preserve existing
        displayName: displayName,
        role: current.role,
        isActive: current.isActive,
        mustChangePassword: current.mustChangePassword,
      ),
    );

    return Response.ok(
      jsonEncode(_userJson(updated)),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── Avatar upload / delete ────────────────────────────────────

  /// Max raw upload size: 5 MB.
  static const _maxAvatarBytes = 5 * 1024 * 1024;

  /// Allowed MIME types for avatar upload.
  static const _allowedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  Future<Response> _uploadAvatar(Request request) async {
    final auth = requireAuthUser(request);
    final contentType = request.headers['content-type'] ?? '';

    if (!contentType.contains('multipart/form-data')) {
      throw const InvalidInputException(
        'Content-Type must be multipart/form-data.',
      );
    }

    final boundary = _extractBoundary(contentType);
    if (boundary == null) {
      throw const InvalidInputException('Missing multipart boundary.');
    }

    // Parse multipart parts.
    final transformer = MimeMultipartTransformer(boundary);
    final parts = await transformer.bind(request.read()).toList();

    List<int>? fileBytes;
    String? fileMime;

    for (final part in parts) {
      final disposition = part.headers['content-disposition'] ?? '';
      if (!disposition.contains('name="file"') &&
          !disposition.contains('filename=')) {
        // Drain unneeded parts.
        await part.fold<void>(null, (_, _) {});
        continue;
      }

      final bytes = await part.fold<List<int>>(
        <int>[],
        (acc, chunk) {
          if (acc.length + chunk.length > _maxAvatarBytes) {
            throw const InvalidInputException(
              'File too large. Maximum size is 5 MB.',
            );
          }
          acc.addAll(chunk);
          return acc;
        },
      );

      fileBytes = bytes;

      // Detect MIME from the part header or fall back to extension sniffing.
      final partType = part.headers['content-type'];
      fileMime = partType ?? lookupMimeType('file', headerBytes: bytes);
    }

    if (fileBytes == null || fileBytes.isEmpty) {
      throw const InvalidInputException('No file provided.');
    }

    fileMime ??= lookupMimeType('file', headerBytes: fileBytes);

    if (fileMime == null || !_allowedMimeTypes.contains(fileMime)) {
      throw const InvalidInputException(
        'Unsupported image format. Allowed: JPEG, PNG, WebP.',
      );
    }

    // Decode, resize, and encode to PNG.
    final decoded = img.decodeImage(Uint8List.fromList(fileBytes));
    if (decoded == null) {
      throw const InvalidInputException('Could not decode image.');
    }

    // Resize if either dimension exceeds 1024px, preserving aspect ratio.
    final resized = (decoded.width > 1024 || decoded.height > 1024)
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? 1024 : null,
            height: decoded.height > decoded.width ? 1024 : null,
            interpolation: img.Interpolation.linear,
          )
        : decoded;

    final pngBytes = img.encodePng(resized);
    final base64Png = base64Encode(pngBytes);

    await metadataStore.setAvatar(auth.userId, base64Png);

    final updated = await metadataStore.lookupUserById(auth.userId);
    return Response.ok(
      jsonEncode({'avatarUrl': _avatarUrl(updated!)}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _deleteAvatar(Request request) async {
    final auth = requireAuthUser(request);
    await metadataStore.deleteAvatar(auth.userId);
    return Response(204);
  }

  Future<Response> _serveAvatar(Request request, String userId) async {
    final base64Data = await metadataStore.getAvatar(userId);
    if (base64Data == null) {
      return Response(404, body: 'No avatar');
    }
    final bytes = base64Decode(base64Data);
    return Response.ok(
      bytes,
      headers: {
        'content-type': 'image/png',
        'cache-control': 'public, max-age=3600',
      },
    );
  }

  String? _extractBoundary(String contentType) {
    final match = RegExp(
      r'boundary=(?:"([^"]+)"|([^\s;]+))',
    ).firstMatch(contentType);
    return (match?.group(1) ?? match?.group(2))?.trim();
  }

  Future<Response> _changePassword(Request request) async {
    final auth = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final currentPassword = body['currentPassword'] as String? ?? '';
    final newPassword = body['newPassword'] as String? ?? '';

    if (currentPassword.isEmpty || newPassword.isEmpty) {
      throw const InvalidInputException(
        'Current password and new password are required.',
      );
    }
    if (newPassword.length < 8) {
      throw const InvalidInputException(
        'New password must be at least 8 characters.',
      );
    }
    if (newPassword.length > AuthService.maxPasswordLength) {
      throw InvalidInputException(
        'New password must be at most ${AuthService.maxPasswordLength} characters.',
      );
    }

    await authService.changePassword(
      userId: auth.userId,
      currentPassword: currentPassword,
      newPassword: newPassword,
    );

    // changePassword revoked every session — including the cookie that
    // made this request. Clear cookies so the browser doesn't keep trying
    // a dead session; user will log in again with the new password.
    final secure = isHttpsRequest(request, trustProxy: trustProxy);
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: <String, Object>{
        'content-type': 'application/json',
        'set-cookie': buildClearedAuthCookies(secure: secure),
      },
    );
  }

  // ── Personal access tokens (API keys) ───────────────────────

  Future<Response> _createKey(Request request) async {
    final auth = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String? ?? '').trim();
    final scopesList =
        (body['scopes'] as List<dynamic>?)?.map((s) => s.toString()).toList() ??
        [TokenScope.read, TokenScope.write];
    final expiresInDays = body['expiresInDays'] as int?;

    if (name.isEmpty) {
      throw const InvalidInputException('Key name is required.');
    }
    // A user can't hand out scopes they themselves don't hold.
    final allowed = scopesForRole(auth.role).toSet();
    for (final s in scopesList) {
      if (!TokenScope.isValid(s)) {
        throw InvalidInputException('Unknown scope: $s');
      }
      if (!allowed.contains(s)) {
        throw ForbiddenException(
          'Your role does not permit the $s scope.',
        );
      }
    }

    final expiresAt = expiresInDays != null
        ? DateTime.now().toUtc().add(Duration(days: expiresInDays))
        : null;

    final result = await authService.createPersonalAccessToken(
      userId: auth.userId,
      name: name,
      scopes: scopesList,
      expiresAt: expiresAt,
    );

    return Response(
      201,
      body: jsonEncode({
        'id': result.token.tokenId,
        'name': result.token.name,
        'secret': result.rawSecret, // shown once
        'prefix': result.token.prefix,
        'scopes': result.token.scopes,
        'createdAt': result.token.createdAt.toIso8601String(),
        'expiresAt': result.token.expiresAt?.toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _listKeys(Request request) async {
    final auth = requireAuthUser(request);
    final tokens = await authService.listTokens(
      auth.userId,
      kind: ApiTokenKind.pat,
    );
    return Response.ok(
      jsonEncode({
        'keys': tokens.where((t) => !t.isRevoked).map(_patJson).toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _revokeKey(Request request, String tokenId) async {
    final auth = requireAuthUser(request);
    await _revokeOwned(
      auth: auth,
      tokenId: tokenId,
      expected: ApiTokenKind.pat,
    );
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── Active sessions ─────────────────────────────────────────

  Future<Response> _listSessions(Request request) async {
    final auth = requireAuthUser(request);
    final tokens = await authService.listTokens(
      auth.userId,
      kind: ApiTokenKind.session,
    );
    return Response.ok(
      jsonEncode({
        'sessions': tokens
            .where((t) => !t.isRevoked && !t.isExpired)
            .map((t) => _sessionJson(t, currentTokenId: auth.tokenId))
            .toList(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _revokeSession(Request request, String tokenId) async {
    final auth = requireAuthUser(request);
    await _revokeOwned(
      auth: auth,
      tokenId: tokenId,
      expected: ApiTokenKind.session,
    );

    // If the user revoked the very session they're using, also clear the
    // cookies so the next request doesn't spam 401s.
    final headers = <String, Object>{'content-type': 'application/json'};
    if (tokenId == auth.tokenId) {
      final secure = isHttpsRequest(request, trustProxy: trustProxy);
      headers['set-cookie'] = buildClearedAuthCookies(secure: secure);
    }
    return Response.ok(jsonEncode({'status': 'ok'}), headers: headers);
  }

  Future<Response> _revokeOtherSessions(Request request) async {
    final auth = requireAuthUser(request);
    if (auth.tokenKind != ApiTokenKind.session) {
      throw const ForbiddenException(
        'This endpoint requires a web session; use an API key endpoint '
        'instead when calling from a PAT.',
      );
    }
    final sessions = await authService.listTokens(
      auth.userId,
      kind: ApiTokenKind.session,
    );
    for (final s in sessions) {
      if (s.tokenId == auth.tokenId) continue;
      if (s.isRevoked) continue;
      await authService.revokeToken(
        tokenId: s.tokenId,
        actingUserId: auth.userId,
      );
    }
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  }

  // ── Helpers ─────────────────────────────────────────────────

  Future<void> _revokeOwned({
    required AuthenticatedUser auth,
    required String tokenId,
    required ApiTokenKind expected,
  }) async {
    // List and check — lookupTokenByHash is the only index-friendly path
    // in the store, so we pull the user's list (small) and match by id.
    final tokens = await authService.listTokens(
      auth.userId,
      kind: expected,
    );
    final match = tokens.where((t) => t.tokenId == tokenId);
    if (match.isEmpty) {
      throw const NotFoundException('Token not found.');
    }
    await authService.revokeToken(
      tokenId: tokenId,
      actingUserId: auth.userId,
    );
  }

  Map<String, dynamic> _userJson(User user) => {
    'userId': user.userId,
    'email': user.email,
    'displayName': user.displayName,
    'role': user.role.name,
    'isAdmin': user.isAdmin,
    'mustChangePassword': user.mustChangePassword,
    'avatarUrl': user.hasAvatar ? _avatarUrl(user) : null,
  };

  String _avatarUrl(User user) =>
      '/api/users/${user.userId}/avatar?v=${user.updatedAt.millisecondsSinceEpoch}';

  Map<String, dynamic> _patJson(ApiToken t) => {
    'id': t.tokenId,
    'name': t.name,
    'prefix': t.prefix,
    'scopes': t.scopes,
    'createdAt': t.createdAt.toIso8601String(),
    'expiresAt': t.expiresAt?.toIso8601String(),
    'lastUsedAt': t.lastUsedAt?.toIso8601String(),
  };

  Map<String, dynamic> _sessionJson(
    ApiToken t, {
    required String currentTokenId,
  }) => {
    'id': t.tokenId,
    'userAgent': t.userAgent,
    'clientIp': t.clientIp,
    'clientCity': t.clientCity,
    'clientRegion': t.clientRegion,
    'clientCountry': t.clientCountry,
    'clientCountryCode': t.clientCountryCode,
    'createdAt': t.createdAt.toIso8601String(),
    'expiresAt': t.expiresAt?.toIso8601String(),
    'absoluteExpiresAt': t.absoluteExpiresAt?.toIso8601String(),
    'lastUsedAt': t.lastUsedAt?.toIso8601String(),
    'current': t.tokenId == currentTokenId,
  };

  String? _clientIp(Request request) {
    // Same trust calculus as cookie Secure — only honor a client-supplied
    // X-Forwarded-For when we're explicitly behind a proxy. Otherwise an
    // attacker hitting the server directly could plant an arbitrary
    // string in the audit log and Sessions UI.
    if (trustProxy) {
      final forwarded = request.headers['x-forwarded-for'];
      if (forwarded != null && forwarded.isNotEmpty) {
        return forwarded.split(',').first.trim();
      }
    }
    final connInfo = request.context['shelf.io.connection_info'];
    if (connInfo is HttpConnectionInfo) {
      return connInfo.remoteAddress.address;
    }
    return null;
  }
}
