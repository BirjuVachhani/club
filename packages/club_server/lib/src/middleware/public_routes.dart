/// The single source of truth for which routes the auth middleware lets
/// through unauthenticated. Changes here require a corresponding update
/// to `test/unit/middleware/public_routes_test.dart`, which pins the
/// surface and forces a deliberate review.
///
/// Club is a private repository. Default policy is "auth-required"; the
/// constants below carve out the minimum needed to (1) bootstrap the
/// system, (2) let new users in, and (3) carry out OAuth.
library;

/// Routes that match a request path *exactly* and skip authentication.
/// Prefer this over [publicPathPrefixes] for everything that can be
/// enumerated.
const Set<String> publicExactPaths = {
  // Healthcheck (Docker / load balancers).
  '/api/v1/health',

  // Footer version pill — rendered for signed-out visitors too, so it
  // can't sit behind auth. Returns just the running version string;
  // see version_api.dart.
  '/api/v1/version',

  // Login + session bootstrap (the SPA's first call). `_me` returns 401
  // on its own when no session is present.
  '/api/auth/login',
  '/api/auth/me',
  '/api/auth/signup',

  // First-run setup wizard. Further gated by `setupGuardMiddleware`:
  // these become 410-Gone once setup completes.
  '/api/setup/status',
  '/api/setup/verify',
  '/api/setup/complete',

  // Privacy/terms linked from login/signup pages, so they have to render
  // before the user has a session. Admin mutations live under
  // `/api/admin/legal` (auth-required).
  '/api/legal/privacy',
  '/api/legal/terms',

  // OAuth: /authorize is the entry of the CLI flow (redirects to the
  // SPA login if needed); /token is gated cryptographically by PKCE
  // (see oauth_api.dart).
  '/oauth/authorize',
  '/oauth/token',
};

/// Routes that match a request path by `startsWith` and skip
/// authentication. **Footgun**: an entry like `/api/packages` would
/// silently expose every `/api/packages/*` route, including future ones
/// a contributor adds. Each entry below documents why the route family
/// genuinely cannot be enumerated.
const Set<String> publicPathPrefixes = {
  // Invitee has no account yet, so they can't authenticate to look up
  // or accept their invite. Token is variable so the route family can't
  // be enumerated as exact paths:
  //   GET  /api/invites/<token>
  //   POST /api/invites/<token>/accept
  '/api/invites/',

  // Avatars render via `<img src>` on login/signup/invite landing pages
  // (pre-session). Variable userId means we can't enumerate; only
  // `/api/users/<userId>/avatar` is registered today (verified by the
  // test alongside this file). Adding any new `/api/users/...` route
  // MUST also confirm whether it should be public — the prefix will
  // swallow it by default.
  '/api/users/',
};
