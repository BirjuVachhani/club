import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf.dart';

import '../auth/cookies.dart';

/// Key used to store [AuthenticatedUser] in the request context.
const String authContextKey = 'club.auth';

/// Extract authenticated user from request context.
AuthenticatedUser? getAuthUser(Request request) =>
    request.context[authContextKey] as AuthenticatedUser?;

/// Extract authenticated user or throw 401.
AuthenticatedUser requireAuthUser(Request request) {
  final user = getAuthUser(request);
  if (user == null) throw AuthException.missingToken();
  return user;
}

/// Ensure the authenticated user holds at least [minRole]. Throws
/// [ForbiddenException] otherwise. Use this everywhere a handler gates on
/// role — never inspect `user.role` directly.
AuthenticatedUser requireRole(Request request, UserRole minRole) {
  final user = requireAuthUser(request);
  if (!user.role.isAtLeast(minRole)) {
    throw ForbiddenException.notAdmin();
  }
  return user;
}

/// Which credential transport authenticated the request — a session
/// cookie, a Bearer PAT, or nothing. Callers that need to gate behavior
/// (e.g. CSRF enforcement) branch on this.
enum AuthTransport { none, cookie, bearer }

/// Middleware that authenticates the request via either:
///
///   1. The `club_session` cookie (web UI path). Requires CSRF on mutations.
///   2. `Authorization: Bearer <token>` where the token is a session or a
///      PAT (`club_pat_...`). PATs skip CSRF entirely since they can't be
///      planted in a victim's browser by an attacker.
///
/// Routes in [publicPaths] skip authentication entirely.
Middleware authMiddleware(
  AuthService authService, {
  Set<String> publicPaths = const {},
}) {
  return (Handler innerHandler) {
    return (Request request) async {
      final path = '/${request.url.path}';

      // SPA pages and non-API routes pass through untouched. Only API and
      // OAuth server endpoints are candidates for auth enforcement.
      final isApiRoute = path.startsWith('/api/');
      final isOAuthServerEndpoint =
          path == '/oauth/authorize' ||
          path == '/oauth/approve' ||
          path == '/oauth/token' ||
          path.startsWith('/oauth/pending/');
      if (!isApiRoute && !isOAuthServerEndpoint) {
        return innerHandler(request);
      }

      // Explicitly public API paths (login, health, etc) skip auth.
      final isPublic = publicPaths.any((p) => path.startsWith(p));

      // Try cookie first so that browsers get the session path; fall back
      // to Bearer for CLI / programmatic callers.
      final cookies = parseCookieHeader(
        request.headers[HttpHeaders.cookieHeader],
      );
      final sessionCookie = cookies[AuthCookies.session];

      final authHeader = request.headers[HttpHeaders.authorizationHeader];
      final bearer = (authHeader != null && authHeader.startsWith('Bearer '))
          ? authHeader.substring('Bearer '.length).trim()
          : null;

      // Attempt to resolve a user regardless of public-ness so that public
      // handlers can still personalise responses (e.g. /api/auth/me) and
      // so the CSRF enforcement below can run uniformly.
      AuthenticatedUser? user;
      AuthTransport transport = AuthTransport.none;
      String? usedSessionCookie;
      AuthException? cookieError;
      AuthException? bearerError;

      if (sessionCookie != null && sessionCookie.isNotEmpty) {
        try {
          user = await authService.authenticateToken(sessionCookie);
          transport = AuthTransport.cookie;
          usedSessionCookie = sessionCookie;
        } on AuthException catch (e) {
          cookieError = e;
        }
      }
      if (user == null && bearer != null && bearer.isNotEmpty) {
        try {
          // Bearer sessions don't slide — a bearer session (copy-pasted
          // somewhere it shouldn't be) shouldn't be able to keep itself
          // alive indefinitely without re-authenticating through the cookie.
          user = await authService.authenticateToken(
            bearer,
            sessionSlidable: false,
          );
          transport = AuthTransport.bearer;
        } on AuthException catch (e) {
          bearerError = e;
        }
      }

      // CSRF is enforced on ANY cookie-authenticated, state-changing
      // request — including requests whose path happens to sit under a
      // [publicPaths] prefix. Making this conditional on `!isPublic`
      // created a cross-site-scripting-to-state-change escalator when
      // the allowlist accidentally swallowed whole route families (e.g.
      // a `/api/packages` entry matching all of `/api/packages/*`).
      // SameSite=Lax alone does not stop same-origin script-initiated
      // mutations, so the double-submit check is load-bearing here.
      //
      // PAT-authenticated callers (`Authorization: Bearer club_pat_...`)
      // continue to skip this check by design: a PAT cannot be planted
      // in a victim's browser by an attacker.
      if (transport == AuthTransport.cookie &&
          _isStateChanging(request.method)) {
        final csrfCookie = cookies[AuthCookies.csrf];
        final csrfHeader = request.headers[AuthCookies.csrfHeader];
        if (csrfCookie == null ||
            csrfCookie.isEmpty ||
            csrfHeader == null ||
            csrfHeader.isEmpty ||
            !_constantTimeEquals(csrfCookie, csrfHeader)) {
          return Response(
            403,
            body:
                '{"error":{"code":"CsrfMismatch","message":"CSRF token missing or invalid."}}',
            headers: {'content-type': 'application/json'},
          );
        }
      }

      if (isPublic) {
        // For public routes, propagate whatever user we did resolve so
        // the handler can tailor its response, and drop any auth errors
        // silently so the handler still runs.
        if (user != null) {
          return innerHandler(_withAuth(request, user, usedSessionCookie));
        }
        return innerHandler(request);
      }

      // Non-public API / OAuth endpoint — auth is required. Prefer a
      // cookie error if we saw one (user was trying to auth via browser
      // session but it was expired/invalid); else bearer error; else a
      // generic "missing" response so unauthenticated clients get a
      // WWW-Authenticate header they can react to.
      if (user == null) {
        if (cookieError != null) return _authError(cookieError);
        if (bearerError != null) return _authError(bearerError);
        return Response(
          401,
          body:
              '{"error":{"code":"MissingAuthentication","message":"Authentication required."}}',
          headers: {
            'content-type': 'application/json',
            'www-authenticate':
                'Bearer realm="pub", message="Authentication required."',
          },
        );
      }

      return innerHandler(_withAuth(request, user, usedSessionCookie));
    };
  };
}

Request _withAuth(
  Request request,
  AuthenticatedUser user,
  // Reserved for future middleware that needs the raw cookie value
  // (currently unused — `AuthenticatedUser.tokenId` covers existing
  // callers that want to act on "this exact session").
  String? _,
) {
  return request.change(
    context: <String, Object>{...request.context, authContextKey: user},
  );
}

Response _authError(AuthException e) {
  return Response(
    401,
    body: '{"error":{"code":"${e.code}","message":"${e.message}"}}',
    headers: {
      'content-type': 'application/json',
      'www-authenticate': 'Bearer realm="pub", message="${e.message}"',
    },
  );
}

bool _isStateChanging(String method) {
  final m = method.toUpperCase();
  return m == 'POST' || m == 'PUT' || m == 'PATCH' || m == 'DELETE';
}

/// Constant-time string comparison. Comparing secrets with `==` leaks
/// length and common-prefix timing. Short strings so iteration cost is
/// negligible.
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
