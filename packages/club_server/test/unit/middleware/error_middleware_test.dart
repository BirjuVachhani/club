import 'dart:convert';

import 'package:club_core/club_core.dart';
import 'package:club_server/src/http/auth_challenge.dart';
import 'package:club_server/src/middleware/error_middleware.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  group('errorMiddleware', () {
    test('renders missing TXT verification failures as 404', () async {
      final handler = const Pipeline()
          .addMiddleware(errorMiddleware())
          .addHandler((_) async {
            throw VerificationNotFoundException('_club-verify.example.com');
          });

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/publishers/verify/complete'),
        ),
      );

      expect(response.statusCode, 404);
      expect(response.headers['content-type'], 'application/json');

      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body, {
        'error': {
          'code': 'NotFound',
          'message':
              'Verification TXT record at "_club-verify.example.com" was not found or did not '
              'contain the expected value. Add or update the record and try '
              'again after DNS propagation.',
        },
      });
    });

    test('renders transient DNS verification failures as 503', () async {
      final handler = const Pipeline()
          .addMiddleware(errorMiddleware())
          .addHandler((_) async {
            throw const VerificationTemporaryFailure('DNS lookup failed.');
          });

      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/publishers/verify/complete'),
        ),
      );

      expect(response.statusCode, 503);

      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body, {
        'error': {
          'code': 'VerificationTemporarilyUnavailable',
          'message': 'DNS lookup failed.',
        },
      });
    });

    // `dart pub publish` reaches endpoints that call `requireAuthUser`
    // rather than being denied by authMiddleware, so the AuthException
    // travels through this middleware. Without the challenge header the
    // pub client treats the 401 as fatal instead of prompting for
    // credentials.
    test('attaches WWW-Authenticate to a handler-thrown AuthException',
        () async {
      final handler = const Pipeline()
          .addMiddleware(errorMiddleware())
          .addHandler((_) async => throw AuthException.tokenExpired());

      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/packages/versions/new'),
        ),
      );

      expect(response.statusCode, 401);
      expect(
        response.headers['www-authenticate'],
        'Bearer realm="pub", message="Token has expired."',
      );
    });

    test('does not attach WWW-Authenticate to non-auth failures', () async {
      final handler = const Pipeline()
          .addMiddleware(errorMiddleware())
          .addHandler((_) async => throw ForbiddenException.notAdmin());

      final response = await handler(
        Request('DELETE', Uri.parse('http://localhost/api/packages/foo')),
      );

      expect(response.statusCode, 403);
      expect(response.headers['www-authenticate'], isNull);
    });
  });

  group('bearerChallenge', () {
    test('escapes quotes and drops CR/LF so the header cannot be split', () {
      final value = bearerChallenge('Token for "a\r\nb" expired.');

      expect(value, 'Bearer realm="pub", message="Token for \\"ab\\" expired."');
      expect(value, isNot(contains('\r')));
      expect(value, isNot(contains('\n')));
    });

    test('escapes backslashes', () {
      expect(
        bearerChallenge(r'path\to'),
        r'Bearer realm="pub", message="path\\to"',
      );
    });
  });
}
