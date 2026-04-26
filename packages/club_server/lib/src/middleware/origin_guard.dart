import 'package:shelf/shelf.dart';

/// Blocks cross-site state-changing requests on endpoints that accept
/// unauthenticated traffic — specifically login, signup, setup, and
/// invite acceptance. These endpoints have no session cookie yet, so the
/// cookie-bound CSRF check in [authMiddleware] can't protect them; an
/// attacker could otherwise POST the victim's browser at `/api/auth/login`
/// with attacker-chosen credentials and log the victim into the attacker's
/// account (login-fixation / login CSRF).
///
/// Strategy: require the request's `Origin` (or `Referer` when `Origin`
/// is absent) to match one of the trusted origins. The server's own
/// [serverUrl] is always trusted; additional origins are opt-in via
/// [AppConfig.allowedOrigins].
///
/// We intentionally *only* guard POST/PUT/PATCH/DELETE on a fixed list
/// of unauthenticated endpoints — public GETs (health, /me, etc.) are
/// read-only and don't need this.
Middleware originGuardMiddleware({
  required Uri? serverUrl,
  required List<String> allowedOrigins,
  required bool trustProxy,
  Set<String> guardedPaths = const {
    '/api/auth/login',
    '/api/auth/signup',
    '/api/setup/verify',
    '/api/setup/complete',
  },
  // Invite accept lives at `/api/invites/<token>/accept` — variable token
  // in the path means we need a prefix match. Anything under `/api/invites/`
  // that's a state-changing method is guarded.
  Set<String> guardedPrefixes = const {
    '/api/invites/',
  },
}) {
  // Explicit trust list from config. Each entry is normalized to
  // "scheme://host[:port]" with no path.
  final configured = <String>{
    if (serverUrl != null) _origin(serverUrl),
    ...allowedOrigins.map((raw) {
      try {
        return _origin(Uri.parse(raw));
      } catch (_) {
        return '';
      }
    }),
  }..removeWhere((o) => o.isEmpty);

  return (Handler inner) {
    return (Request request) async {
      if (!_stateChanging(request.method)) return inner(request);

      final path = '/${request.url.path}';
      final isGuarded =
          guardedPaths.contains(path) ||
          guardedPrefixes.any((p) => path.startsWith(p));
      if (!isGuarded) return inner(request);

      final origin = request.headers['origin'];
      final referer = request.headers['referer'];

      final claimed = origin ?? (referer != null ? _tryOrigin(referer) : null);

      if (claimed == null || claimed.isEmpty) {
        return _deny('missing Origin/Referer');
      }

      // The request's own effective origin — what the browser believes
      // it's talking to. For direct hits (localhost:10234, dev boxes,
      // non-proxied deployments) this IS the trusted origin, no config
      // required. For proxied deployments, X-Forwarded-Proto/Host give
      // us the client-facing URL when TRUST_PROXY is on.
      //
      // Safe to auto-trust: browsers populate `Origin` themselves and
      // can't be tricked by a third-party site into claiming our origin.
      // If Origin == our own scheme+host+port, the request came from a
      // page served by us.
      final self = _effectiveOrigin(request, trustProxy: trustProxy);

      final trusted = <String>{...configured, ?self};

      if (!trusted.contains(claimed.toLowerCase())) {
        return _deny('origin $claimed not allowed');
      }

      return inner(request);
    };
  };
}

/// Compute the scheme+authority the browser was actually talking to.
///
/// When `trustProxy` is true, prefer `X-Forwarded-Proto` / `X-Forwarded-Host`
/// (the proxy tells us how the client addressed it). Otherwise derive
/// from the request URL and the `Host` header — which together represent
/// the direct TCP peer's view, the same view the browser has when not
/// proxied.
String? _effectiveOrigin(Request request, {required bool trustProxy}) {
  String? scheme;
  String? host;

  if (trustProxy) {
    final fwdProto = request.headers['x-forwarded-proto']
        ?.split(',')
        .first
        .trim()
        .toLowerCase();
    if (fwdProto != null && fwdProto.isNotEmpty) scheme = fwdProto;

    final fwdHost = request.headers['x-forwarded-host']
        ?.split(',')
        .first
        .trim();
    if (fwdHost != null && fwdHost.isNotEmpty) host = fwdHost;
  }

  scheme ??= request.requestedUri.scheme;

  // `Host` header carries host:port as seen by the listening socket;
  // authority on the parsed URI is a fine fallback and already includes
  // the port for non-default cases.
  host ??= request.headers['host'] ?? request.requestedUri.authority;

  if (scheme.isEmpty || host.isEmpty) return null;
  try {
    return _origin(Uri.parse('$scheme://$host'));
  } catch (_) {
    return null;
  }
}

String _origin(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  return '$scheme://$host$port';
}

String? _tryOrigin(String url) {
  try {
    return _origin(Uri.parse(url));
  } catch (_) {
    return null;
  }
}

bool _stateChanging(String method) {
  final m = method.toUpperCase();
  return m == 'POST' || m == 'PUT' || m == 'PATCH' || m == 'DELETE';
}

Response _deny(String reason) {
  return Response(
    403,
    body:
        '{"error":{"code":"CrossSiteRequest","message":"This endpoint only accepts same-origin requests ($reason)."}}',
    headers: {'content-type': 'application/json'},
  );
}
