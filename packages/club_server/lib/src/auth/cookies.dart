import 'dart:math';

import 'package:shelf/shelf.dart';

/// Cookie names kept in one place so the middleware, auth API, and any
/// future callers stay in sync.
class AuthCookies {
  AuthCookies._();

  /// HttpOnly session cookie. Never readable from JavaScript; carries the
  /// raw session token that the middleware validates against [ApiToken].
  static const String session = 'club_session';

  /// Double-submit CSRF cookie. Intentionally not HttpOnly — the SPA reads
  /// it and echoes it in an `X-CSRF-Token` header on state-changing
  /// requests, which proves the request originated from a same-site page
  /// rather than a malicious cross-site form.
  static const String csrf = 'club_csrf';

  /// Header the SPA uses to echo the CSRF cookie.
  static const String csrfHeader = 'x-csrf-token';
}

/// Secure attribute decision. `Secure` cookies are only sent over HTTPS,
/// so in local dev (http://localhost) we must emit them without it or the
/// browser drops the cookie and the user can't log in at all.
///
/// When [trustProxy] is false, client-supplied `X-Forwarded-Proto` is
/// ignored entirely — an attacker reaching the server directly could
/// otherwise spoof HTTPS and induce the server to emit `Secure` cookies
/// over plaintext, which the browser would then refuse to send back.
/// Operators behind a reverse proxy opt in via `TRUST_PROXY=true`.
///
/// Localhost-safe invariant: `trustProxy=true` only *adds* a header
/// check. The direct-scheme fallback at the bottom still fires when no
/// `X-Forwarded-Proto` is present, so a laptop hitting the server
/// directly at http://localhost:8080 (bypassing any proxy) keeps
/// working — no separate dev/prod config is required. Preserve this
/// property if you ever refactor this function.
bool isHttpsRequest(Request request, {required bool trustProxy}) {
  if (trustProxy) {
    final forwarded = request.headers['x-forwarded-proto']?.toLowerCase();
    if (forwarded != null && forwarded.isNotEmpty) {
      return forwarded.split(',').first.trim() == 'https';
    }
  }
  return request.requestedUri.scheme == 'https';
}

String _fmt({
  required String name,
  required String value,
  required int maxAgeSeconds,
  required bool secure,
  required bool httpOnly,
  String path = '/',
  // `Lax` sends cookies on top-level GET navigations from cross-site links
  // (common UX, e.g. clicking an emailed link to /packages/foo) while still
  // blocking cross-site POSTs. The double-submit CSRF token provides the
  // actual CSRF defense on state-changing requests; SameSite is
  // defense-in-depth. `Strict` would break the "click a link to CLUB from
  // elsewhere and stay signed in" case.
  String sameSite = 'Lax',
}) {
  final parts = <String>[
    '$name=$value',
    'Path=$path',
    'Max-Age=$maxAgeSeconds',
    'SameSite=$sameSite',
  ];
  if (httpOnly) parts.add('HttpOnly');
  if (secure) parts.add('Secure');
  return parts.join('; ');
}

/// Build a `Set-Cookie` value for the session cookie.
String buildSessionCookie({
  required String rawSecret,
  required Duration maxAge,
  required bool secure,
}) {
  return _fmt(
    name: AuthCookies.session,
    value: rawSecret,
    maxAgeSeconds: maxAge.inSeconds,
    httpOnly: true,
    secure: secure,
  );
}

/// Build a `Set-Cookie` value for the CSRF cookie.
String buildCsrfCookie({
  required String value,
  required Duration maxAge,
  required bool secure,
}) {
  return _fmt(
    name: AuthCookies.csrf,
    value: value,
    maxAgeSeconds: maxAge.inSeconds,
    httpOnly: false,
    secure: secure,
  );
}

/// Build `Set-Cookie` values that clear both auth cookies. Use on logout.
List<String> buildClearedAuthCookies({required bool secure}) {
  return [
    _fmt(
      name: AuthCookies.session,
      value: '',
      maxAgeSeconds: 0,
      httpOnly: true,
      secure: secure,
    ),
    _fmt(
      name: AuthCookies.csrf,
      value: '',
      maxAgeSeconds: 0,
      httpOnly: false,
      secure: secure,
    ),
  ];
}

/// Parse a Cookie header value (format: `a=b; c=d`) into a map.
Map<String, String> parseCookieHeader(String? header) {
  if (header == null || header.isEmpty) return const {};
  final out = <String, String>{};
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final name = trimmed.substring(0, eq).trim();
    final value = trimmed.substring(eq + 1).trim();
    out[name] = value;
  }
  return out;
}

/// Generate a CSRF token. 32 random hex chars is comfortably over the
/// 128-bit threshold typically recommended against online guessing.
String generateCsrfToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
