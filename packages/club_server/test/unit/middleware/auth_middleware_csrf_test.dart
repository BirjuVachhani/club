import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:club_server/src/auth/cookies.dart';
import 'package:club_server/src/middleware/auth_middleware.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Minimal AuthService double — the middleware only calls
/// `authenticateToken(raw, sessionSlidable: ...)`, so we stub that and
/// route everything else to `noSuchMethod` to keep the test focused on
/// the CSRF branch.
class _FakeAuthService implements AuthService {
  _FakeAuthService(this._user);
  final AuthenticatedUser _user;

  @override
  Future<AuthenticatedUser> authenticateToken(
    String rawToken, {
    bool sessionSlidable = true,
  }) async {
    return _user;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

AuthenticatedUser _user() => AuthenticatedUser(
      userId: 'u1',
      email: 'a@b.c',
      displayName: 'A',
      role: UserRole.member,
      scopes: const [],
      tokenKind: ApiTokenKind.session,
      tokenId: 't1',
    );

Handler _passThrough() => (Request req) async => Response.ok('handled');

void main() {
  group('authMiddleware CSRF enforcement', () {
    // A path that is listed in publicPaths. Before the Vuln 2 fix, a
    // state-changing cookie-authed request here bypassed CSRF entirely.
    const publicPath = '/api/packages/foo';

    test(
      'cookie + POST to public path without CSRF header is rejected',
      () async {
        final mw = authMiddleware(
          _FakeAuthService(_user()),
          publicPaths: const {'/api/packages'},
        );
        final handler = mw(_passThrough());

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$publicPath'),
            headers: {
              'cookie':
                  '${AuthCookies.session}=sess;${AuthCookies.csrf}=abc',
              // CSRF header is missing on purpose.
            },
          ),
        );

        expect(response.statusCode, 403);
        final body = await response.readAsString();
        expect(jsonDecode(body), {
          'error': {
            'code': 'CsrfMismatch',
            'message': 'CSRF token missing or invalid.',
          },
        });
      },
    );

    test(
      'cookie + POST to public path with matching CSRF header passes',
      () async {
        final mw = authMiddleware(
          _FakeAuthService(_user()),
          publicPaths: const {'/api/packages'},
        );
        final handler = mw(_passThrough());

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$publicPath'),
            headers: {
              'cookie':
                  '${AuthCookies.session}=sess;${AuthCookies.csrf}=abc',
              AuthCookies.csrfHeader: 'abc',
            },
          ),
        );

        expect(response.statusCode, 200);
        expect(await response.readAsString(), 'handled');
      },
    );

    test(
      'cookie + GET to public path skips CSRF regardless',
      () async {
        final mw = authMiddleware(
          _FakeAuthService(_user()),
          publicPaths: const {'/api/packages'},
        );
        final handler = mw(_passThrough());

        final response = await handler(
          Request(
            'GET',
            Uri.parse('http://localhost$publicPath'),
            headers: {
              'cookie': '${AuthCookies.session}=sess',
              // No CSRF cookie / header — fine for GET.
            },
          ),
        );

        expect(response.statusCode, 200);
      },
    );

    test(
      'bearer token PAT path on public path skips CSRF',
      () async {
        // PATs can't be planted in a victim's browser, so they're exempt.
        final mw = authMiddleware(
          _FakeAuthService(_user()),
          publicPaths: const {'/api/packages'},
        );
        final handler = mw(_passThrough());

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost$publicPath'),
            headers: {'authorization': 'Bearer club_pat_abc'},
          ),
        );

        expect(response.statusCode, 200);
      },
    );

    test(
      'cookie + POST to NON-public path still requires CSRF',
      () async {
        final mw = authMiddleware(
          _FakeAuthService(_user()),
          publicPaths: const {},
        );
        final handler = mw(_passThrough());

        final response = await handler(
          Request(
            'POST',
            Uri.parse('http://localhost/api/admin/something'),
            headers: {
              'cookie':
                  '${AuthCookies.session}=sess;${AuthCookies.csrf}=abc',
            },
          ),
        );

        expect(response.statusCode, 403);
      },
    );
  });
}
