import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:club_server/src/api/oauth_api.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Both dependencies are stubs — the `/oauth/authorize` error branches we
/// exercise here reject the request before touching either, so neither
/// needs to do anything real.
class _FakeAuthService implements AuthService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeMetadataStore implements MetadataStore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<Response> _authorize(String query) async {
  final api = OAuthApi(
    authService: _FakeAuthService(),
    metadataStore: _FakeMetadataStore(),
  );
  return await api.router.call(
    Request('GET', Uri.parse('http://club.example/oauth/authorize?$query')),
  );
}

void main() {
  group('/oauth/authorize — hostile redirect_uri is never echoed', () {
    // Pinning Vuln 1: before the fix, an attacker-controlled `redirect_uri`
    // could reach `_errorRedirect` via the `response_type`/`client_id`
    // branches and produce a 302 off-origin. The loopback validator now
    // runs first, so these requests must fall into the inline-400 path.

    test('bogus response_type + hostile redirect_uri returns inline 400',
        () async {
      final res = await _authorize(
        'response_type=token&client_id=cli'
        '&redirect_uri=${Uri.encodeComponent('https://attacker.com/phish')}'
        '&state=abc',
      );
      expect(res.statusCode, 400,
          reason: 'must not 302 to an attacker-controlled URL');
      expect(res.headers['location'], isNull);
      expect(res.headers['content-type'], contains('application/json'));
      final body = jsonDecode(await res.readAsString());
      expect(body['error'], 'invalid_request');
    });

    test('missing client_id + hostile redirect_uri returns inline 400',
        () async {
      final res = await _authorize(
        'response_type=code'
        '&redirect_uri=${Uri.encodeComponent('https://attacker.com/phish')}'
        '&state=abc',
      );
      expect(res.statusCode, 400);
      expect(res.headers['location'], isNull);
    });

    test('userinfo trick redirect_uri returns inline 400', () async {
      // `http://localhost@evil.com/` — userinfo-spoofed. Uri.parse gives
      // host=evil.com; the loopback validator must reject.
      final res = await _authorize(
        'response_type=code&client_id=cli'
        '&redirect_uri=${Uri.encodeComponent('http://localhost@evil.com:80/cb')}'
        '&state=abc',
      );
      expect(res.statusCode, 400);
      expect(res.headers['location'], isNull);
    });

    test('look-alike subdomain redirect_uri returns inline 400', () async {
      final res = await _authorize(
        'response_type=code&client_id=cli'
        '&redirect_uri=${Uri.encodeComponent('http://localhost.evil.com:80/cb')}'
        '&state=abc',
      );
      expect(res.statusCode, 400);
      expect(res.headers['location'], isNull);
    });

    test('valid loopback redirect_uri + invalid response_type still 302s back',
        () async {
      // Once loopback is validated, echoing it back for other errors is
      // the OAuth spec-compliant behavior we want to preserve.
      final res = await _authorize(
        'response_type=token&client_id=cli'
        '&redirect_uri=${Uri.encodeComponent('http://localhost:51823/cb')}'
        '&state=abc',
      );
      expect(res.statusCode, 302);
      final location = res.headers['location']!;
      expect(location, startsWith('http://localhost:51823/cb'));
      expect(location, contains('error=unsupported_response_type'));
    });
  });
}
