import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../auth/loopback_redirect.dart';
import '../http/decoded_router.dart';
import '../auth/token_scopes.dart';
import '../middleware/auth_middleware.dart';
// requireAuthUser is re-exported from auth_middleware.dart and used below.

/// OAuth 2.0 Authorization Code flow with PKCE (RFC 7636).
///
/// This is the industry-standard flow for CLI/native app authentication:
///
/// 1. CLI generates code_verifier + code_challenge (S256)
/// 2. CLI opens browser to GET /oauth/authorize?...
/// 3. User logs in (if needed) and sees consent screen
/// 4. User clicks "Authorize"
/// 5. Server issues authorization code, redirects to CLI's localhost
/// 6. CLI exchanges code for token via POST /oauth/token
///
/// Security:
/// - PKCE prevents authorization code interception attacks
/// - Authorization codes are single-use, expire in 5 minutes
/// - State parameter prevents CSRF
/// - Codes are stored in memory (cleared on server restart)
class OAuthApi {
  OAuthApi({required this.authService, required this.metadataStore});

  final AuthService authService;
  final MetadataStore metadataStore;

  /// In-memory authorization code store.
  /// In production you'd use Redis or the database, but for a single-process
  /// server this is fine and avoids unnecessary persistence.
  final Map<String, _AuthorizationCode> _codes = {};

  /// Pending authorization requests (before user approves).
  final Map<String, _PendingAuth> _pending = {};

  DecodedRouter get router {
    final router = DecodedRouter();

    // Step 1: Authorization endpoint — browser navigates here
    router.get('/oauth/authorize', _authorize);

    // Step 3: User approves — called by the web UI
    router.post('/oauth/approve', _approve);

    // Step 4: Token exchange — called by the CLI
    router.post('/oauth/token', _token);

    // Info endpoint — returns pending auth details for the consent screen
    router.get('/oauth/pending/<requestId>', _pendingInfo);

    return router;
  }

  /// GET /oauth/authorize
  ///
  /// Query params:
  /// - response_type=code (required)
  /// - client_id=cli (required)
  /// - `redirect_uri=http://localhost:{port}/callback` (required)
  /// - `code_challenge={base64url}` (required)
  /// - `code_challenge_method=S256` (required)
  /// - `state={random}` (required)
  /// - scope=read,write (optional, default: read,write)
  ///
  /// Redirects to the SPA consent page with a request_id.
  Future<Response> _authorize(Request request) async {
    final params = request.url.queryParameters;

    final responseType = params['response_type'];
    final clientId = params['client_id'];
    final redirectUri = params['redirect_uri'];
    final codeChallenge = params['code_challenge'];
    final codeChallengeMethod = params['code_challenge_method'];
    final state = params['state'];
    final scope = params['scope'] ?? 'read,write';

    // Validate the redirect URI FIRST. Every other validation branch below
    // passes [redirectUri] back to `_errorRedirect`, which builds a 302
    // Location header from it. If we didn't gate that on loopback-only
    // up front, `/oauth/authorize?response_type=foo&redirect_uri=https://
    // evil.com/...` would turn this endpoint into an open-redirect primitive
    // for phishing — the attacker gets a 302 off the registry's origin to
    // any URL they like. Guard against loose prefix-match tricks —
    // `http://localhost.evil.com/` and userinfo like `http://localhost@evil.com/`
    // would previously pass a startsWith check. [redirectUri] must point at
    // a loopback address (localhost, 127.0.0.1, [::1], or ::1 bracketless),
    // over plain http, with an explicit port, and no userinfo. Anything
    // else would make this endpoint an account-takeover primitive.
    if (!isValidLoopbackRedirect(redirectUri)) {
      return _errorRedirect(
        // Don't echo a potentially hostile redirect URI back. The
        // originating error page is returned inline instead.
        null,
        state,
        'invalid_request',
        'redirect_uri must be a http://localhost:<port>/ URL '
            '(loopback only, no userinfo).',
      );
    }
    // From here on, [redirectUri] is guaranteed loopback, so echoing it
    // back to the caller on other errors is safe.
    if (responseType != 'code') {
      return _errorRedirect(
        redirectUri,
        state,
        'unsupported_response_type',
        'Only response_type=code is supported.',
      );
    }
    if (clientId == null || clientId.isEmpty) {
      return _errorRedirect(
        redirectUri,
        state,
        'invalid_request',
        'client_id is required.',
      );
    }
    if (codeChallenge == null || codeChallenge.isEmpty) {
      return _errorRedirect(
        redirectUri,
        state,
        'invalid_request',
        'code_challenge is required (PKCE).',
      );
    }
    if (codeChallengeMethod != 'S256') {
      return _errorRedirect(
        redirectUri,
        state,
        'invalid_request',
        'code_challenge_method must be S256.',
      );
    }
    if (state == null || state.isEmpty) {
      return _errorRedirect(
        redirectUri,
        state,
        'invalid_request',
        'state is required.',
      );
    }

    // Create a pending authorization request. `redirectUri` has been
    // validated as non-null + loopback by [_isValidLoopbackRedirect].
    final requestId = _generateId();
    _pending[requestId] = _PendingAuth(
      clientId: clientId,
      redirectUri: redirectUri!,
      codeChallenge: codeChallenge,
      state: state,
      scope: scope,
      createdAt: DateTime.now().toUtc(),
    );

    // Clean up expired pending requests
    _cleanupExpired();

    // Redirect to the SPA consent page
    return Response.found(
      Uri.parse('/oauth/consent?request_id=$requestId'),
    );
  }

  /// GET /oauth/pending/{requestId}
  ///
  /// Returns info about a pending auth request so the SPA can render the
  /// consent screen. Requires an authenticated session — a logged-in
  /// user has already proven identity and only needs to confirm the
  /// consent. Gating this behind auth prevents anyone who glimpses a
  /// request_id (via Referer, browser history, etc) from learning the
  /// pending metadata.
  Future<Response> _pendingInfo(Request request, String requestId) async {
    requireAuthUser(request);

    final pending = _pending[requestId];
    if (pending == null || pending.isExpired) {
      _pending.remove(requestId);
      return Response(
        400,
        body: jsonEncode({
          'error': 'invalid_request',
          'error_description': 'Authorization request expired or not found.',
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    return Response.ok(
      jsonEncode({
        'request_id': requestId,
        'client_id': pending.clientId,
        'scope': pending.scope,
        'redirect_uri': pending.redirectUri,
        'state': pending.state,
        'created_at': pending.createdAt.toIso8601String(),
      }),
      headers: {'content-type': 'application/json'},
    );
  }

  /// POST /oauth/approve
  ///
  /// Called by the web UI after the user clicks "Authorize".
  /// Requires authentication (the user must be logged in).
  ///
  /// Body: `{ "request_id": "{id}" }`
  /// Returns: `{ "redirect_url": "http://localhost:{port}/callback?code={code}&state={state}" }`
  Future<Response> _approve(Request request) async {
    final user = requireAuthUser(request);
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final requestId = body['request_id'] as String? ?? '';

    final pending = _pending.remove(requestId);
    if (pending == null || pending.isExpired) {
      return Response(
        400,
        body: jsonEncode({
          'error': 'invalid_request',
          'error_description': 'Authorization request expired or not found.',
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Generate authorization code
    final code = _generateId();
    _codes[code] = _AuthorizationCode(
      userId: user.userId,
      clientId: pending.clientId,
      redirectUri: pending.redirectUri,
      codeChallenge: pending.codeChallenge,
      scope: pending.scope,
      createdAt: DateTime.now().toUtc(),
    );

    // Build redirect URL with code and state
    final redirectUrl = Uri.parse(pending.redirectUri).replace(
      queryParameters: {
        'code': code,
        'state': pending.state,
      },
    );

    return Response.ok(
      jsonEncode({'redirect_url': redirectUrl.toString()}),
      headers: {'content-type': 'application/json'},
    );
  }

  /// POST /oauth/token
  ///
  /// Token exchange endpoint. Called by the CLI after receiving the code.
  /// No authentication required — PKCE verifier proves the caller is legitimate.
  ///
  /// Body (form-urlencoded or JSON):
  /// - grant_type=authorization_code
  /// - `code={authorization_code}`
  /// - `redirect_uri={same as authorize}`
  /// - `code_verifier={original PKCE verifier}`
  Future<Response> _token(Request request) async {
    final Map<String, String> params;
    final contentType = request.headers['content-type'] ?? '';

    if (contentType.contains('application/x-www-form-urlencoded')) {
      final body = await request.readAsString();
      params = Uri.splitQueryString(body);
    } else {
      final json =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      params = json.map((k, v) => MapEntry(k, v.toString()));
    }

    final grantType = params['grant_type'];
    final code = params['code'];
    final redirectUri = params['redirect_uri'];
    final codeVerifier = params['code_verifier'];

    if (grantType != 'authorization_code') {
      return _tokenError(
        'unsupported_grant_type',
        'Only grant_type=authorization_code is supported.',
      );
    }
    if (code == null || code.isEmpty) {
      return _tokenError('invalid_request', 'code is required.');
    }
    if (codeVerifier == null || codeVerifier.isEmpty) {
      return _tokenError('invalid_request', 'code_verifier is required.');
    }

    // Look up and consume the authorization code (single-use)
    final authCode = _codes.remove(code);
    if (authCode == null || authCode.isExpired) {
      _codes.remove(code);
      return _tokenError(
        'invalid_grant',
        'Authorization code expired or not found.',
      );
    }

    // Verify redirect_uri matches
    if (redirectUri != null && redirectUri != authCode.redirectUri) {
      return _tokenError('invalid_grant', 'redirect_uri mismatch.');
    }

    // Verify PKCE: S256(code_verifier) must equal stored code_challenge.
    // Constant-time compare — even though the code is now consumed, we
    // don't want timing to leak any partial match back to the caller.
    final computedChallenge = base64Url
        .encode(sha256.convert(utf8.encode(codeVerifier)).bytes)
        .replaceAll('=', '');

    if (!_constantTimeEquals(computedChallenge, authCode.codeChallenge)) {
      return _tokenError(
        'invalid_grant',
        'PKCE verification failed. code_verifier does not match code_challenge.',
      );
    }

    // Clamp requested scopes to what the user's *current* role permits.
    // The CLI could have asked for "admin" at /authorize; the consent
    // screen doesn't know about scopes, and the SPA doesn't either — so
    // the canonical gate lives here. A viewer who ended up with an
    // `admin`-scoped CLI token would be an escalation vector if any
    // handler checked `hasScope` instead of `requireRole`.
    final user = await metadataStore.lookupUserById(authCode.userId);
    if (user == null || !user.isActive) {
      return _tokenError('invalid_grant', 'User no longer exists.');
    }
    final requested = authCode.scope
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final allowed = scopesForRole(user.role).toSet();
    final granted = requested.where(allowed.contains).toList();
    if (granted.isEmpty) {
      return _tokenError(
        'invalid_scope',
        'None of the requested scopes are permitted for your role.',
      );
    }

    final tokenResult = await authService.createPersonalAccessToken(
      userId: authCode.userId,
      name: 'CLI (${DateTime.now().toIso8601String()})',
      scopes: granted,
    );

    return Response.ok(
      jsonEncode({
        'access_token': tokenResult.rawSecret,
        'token_type': 'Bearer',
        'scope': granted.join(','),
        'email': user.email,
      }),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'pragma': 'no-cache',
      },
    );
  }

  /// Constant-time string compare. Mirrors the helper in auth_middleware
  /// and setup_api — kept local so this file has no security-critical
  /// `==` on secrets.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ── Helpers ──────────────────────────────────────────────

  Response _errorRedirect(
    String? redirectUri,
    String? state,
    String error,
    String description,
  ) {
    if (redirectUri == null) {
      return Response(
        400,
        body: jsonEncode({'error': error, 'error_description': description}),
        headers: {'content-type': 'application/json'},
      );
    }
    final uri = Uri.parse(redirectUri).replace(
      queryParameters: {
        'error': error,
        'error_description': description,
        'state': ?state,
      },
    );
    return Response.found(uri);
  }

  Response _tokenError(String error, String description) => Response(
    400,
    body: jsonEncode({'error': error, 'error_description': description}),
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
    },
  );

  String _generateId() {
    final random = Random.secure();
    final bytes = List.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _cleanupExpired() {
    _pending.removeWhere((_, v) => v.isExpired);
    _codes.removeWhere((_, v) => v.isExpired);
  }
}

class _PendingAuth {
  _PendingAuth({
    required this.clientId,
    required this.redirectUri,
    required this.codeChallenge,
    required this.state,
    required this.scope,
    required this.createdAt,
  });

  final String clientId;
  final String redirectUri;
  final String codeChallenge;
  final String state;
  final String scope;
  final DateTime createdAt;

  /// Pending requests expire after 5 minutes. Short window because the
  /// request_id travels in the consent page URL and is the only secret
  /// guarding pending metadata (scope, redirect_uri, state). Referer
  /// headers and browser history can leak it.
  bool get isExpired =>
      DateTime.now().toUtc().difference(createdAt).inMinutes > 5;
}

class _AuthorizationCode {
  _AuthorizationCode({
    required this.userId,
    required this.clientId,
    required this.redirectUri,
    required this.codeChallenge,
    required this.scope,
    required this.createdAt,
  });

  final String userId;
  final String clientId;
  final String redirectUri;
  final String codeChallenge;
  final String scope;
  final DateTime createdAt;

  /// Authorization codes expire after 5 minutes (RFC 6749 §4.1.2).
  bool get isExpired =>
      DateTime.now().toUtc().difference(createdAt).inMinutes > 5;
}
