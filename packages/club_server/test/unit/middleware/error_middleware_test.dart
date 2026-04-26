import 'dart:convert';

import 'package:club_core/club_core.dart';
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
  });
}
