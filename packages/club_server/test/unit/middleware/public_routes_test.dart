import 'package:club_core/club_core.dart';
import 'package:club_server/src/middleware/auth_middleware.dart';
import 'package:club_server/src/middleware/public_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// AuthService that always rejects — drives the middleware down its
/// "no valid credentials" branch so we can tell whether a path is
/// allow-listed (200) vs. auth-required (401).
class _RejectingAuthService implements AuthService {
  @override
  Future<AuthenticatedUser> authenticateToken(
    String rawToken, {
    bool sessionSlidable = true,
  }) async {
    throw AuthException.tokenExpired();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Handler _passThrough() => (Request req) async => Response.ok('handled');

Future<int> _statusFor(String path, {String method = 'GET'}) async {
  final mw = authMiddleware(
    _RejectingAuthService(),
    publicExactPaths: publicExactPaths,
    publicPathPrefixes: publicPathPrefixes,
  );
  final response = await mw(_passThrough())(
    Request(method, Uri.parse('http://localhost$path')),
  );
  return response.statusCode;
}

void main() {
  // ---------------------------------------------------------------------------
  // Snapshot: pin the exact public surface so any change forces a deliberate
  // edit to this test. If you're updating these expectations, double-check
  // with a security-minded reviewer that the new entry truly needs to be
  // reachable without authentication.
  // ---------------------------------------------------------------------------
  group('public surface snapshot', () {
    test('publicExactPaths matches the approved set', () {
      expect(publicExactPaths, {
        '/api/v1/health',
        '/api/auth/login',
        '/api/auth/me',
        '/api/auth/signup',
        '/api/setup/status',
        '/api/setup/verify',
        '/api/setup/complete',
        '/api/legal/privacy',
        '/api/legal/terms',
        '/oauth/authorize',
        '/oauth/token',
      });
    });

    test('publicPathPrefixes matches the approved set', () {
      // Each prefix MUST justify why the route family can't be enumerated.
      // See public_routes.dart for the reasoning.
      expect(publicPathPrefixes, {
        '/api/invites/',
        '/api/users/',
      });
    });

    test('no exact path is also covered by a prefix (defense in depth)', () {
      // Prevents a sloppy edit where the same route is added to both lists
      // and the prefix entry silently broadens the surface.
      for (final exact in publicExactPaths) {
        for (final prefix in publicPathPrefixes) {
          expect(
            exact.startsWith(prefix),
            isFalse,
            reason:
                'Exact path "$exact" is shadowed by prefix "$prefix" — drop '
                'one of them.',
          );
        }
      }
    });

    test('no prefix accidentally covers a sensitive area', () {
      // A future contributor adding e.g. `/api/packages` here would silently
      // expose the whole package family. Spot-check the obvious offenders.
      const banned = [
        '/api/',
        '/api/packages',
        '/api/packages/',
        '/api/archives',
        '/api/admin',
        '/documentation',
        '/oauth/',
      ];
      for (final p in publicPathPrefixes) {
        expect(
          banned.contains(p),
          isFalse,
          reason:
              '"$p" would expose a route family that must not be public. '
              'If you genuinely need this, propose it explicitly and remove '
              'this guard with a justification.',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Behavioural: drive paths through the real middleware with a rejecting
  // AuthService. 200 ⇒ middleware let it through (public). 401 ⇒ middleware
  // demanded auth.
  // ---------------------------------------------------------------------------
  group('middleware enforcement against the production public surface', () {
    test('every publicExactPath is reachable without auth', () async {
      for (final p in publicExactPaths) {
        expect(
          await _statusFor(p),
          200,
          reason: '$p is in publicExactPaths but middleware blocked it.',
        );
      }
    });

    test('sample paths under each prefix are reachable without auth', () async {
      // One concrete sample per prefix. Adding a prefix above MUST come
      // with a sample here so we can prove the prefix is wired correctly.
      const samples = {
        '/api/invites/': [
          '/api/invites/abc123',
          '/api/invites/abc123/accept',
        ],
        '/api/users/': [
          '/api/users/u1/avatar',
        ],
      };
      expect(samples.keys.toSet(), publicPathPrefixes,
          reason: 'Add a sample for every prefix in publicPathPrefixes.');
      for (final entry in samples.entries) {
        for (final path in entry.value) {
          expect(
            await _statusFor(path),
            200,
            reason: '$path is under prefix ${entry.key} but was blocked.',
          );
        }
      }
    });

    test(
      'previously-anonymous package/search/dartdoc routes now require auth',
      () async {
        // These were anonymous-readable before the public-surface tightening.
        // Any regression here is a privacy leak on a private repo.
        const sensitive = [
          '/api/packages',
          '/api/packages/foo',
          '/api/packages/foo/versions/1.0.0',
          '/api/packages/foo/score',
          '/api/packages/foo/content',
          '/api/packages/foo/versions/1.0.0/screenshots/0.png',
          '/api/packages/foo/versions/1.0.0/readme-assets/diagram.png',
          '/api/packages/foo/downloads',
          '/api/package-name-completion-data',
          '/api/search',
          '/api/archives/foo-1.0.0.tar.gz',
          '/documentation/foo/latest/index.html',
          '/documentation/foo/1.2.3/api/lib.html',
        ];
        for (final p in sensitive) {
          expect(
            await _statusFor(p),
            401,
            reason: '$p must require authentication on a private repo.',
          );
        }
      },
    );

    test(
      'admin and account routes require auth (sanity check)',
      () async {
        const sensitive = [
          '/api/admin/users',
          '/api/admin/packages',
          '/api/admin/sdk/releases',
          '/api/account/packages',
          '/api/account/likes',
          '/api/auth/keys',
          '/api/auth/sessions',
          '/api/publishers',
        ];
        for (final p in sensitive) {
          expect(
            await _statusFor(p),
            401,
            reason: '$p must require authentication.',
          );
        }
      },
    );

    test(
      'OAuth approve and pending endpoints require auth (only authorize+token are public)',
      () async {
        // A common mistake would be to also list /oauth/approve as public.
        // It would let an attacker forge consent from a victim's browser.
        expect(await _statusFor('/oauth/approve', method: 'POST'), 401);
        expect(await _statusFor('/oauth/pending/abc123'), 401);
      },
    );

    test('non-API/oauth/dartdoc paths pass through (SPA static)', () async {
      // The middleware shouldn't touch SPA routes — the static handler
      // serves them. We verify by sending a path that isn't on any of the
      // gated prefixes; rejecting AuthService is irrelevant here because
      // the middleware should short-circuit before calling it.
      expect(await _statusFor('/'), 200);
      expect(await _statusFor('/login'), 200);
      expect(await _statusFor('/packages/foo'), 200);
    });
  });
}
