import 'package:club_server/src/middleware/security_headers.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Club is a private registry, so a response with no `Cache-Control` is a
/// liability: RFC 9111 lets an intermediary heuristically cache a 200 that
/// carries a validator, and hand one user's private package data to the
/// next requester. These tests pin the default and, just as importantly,
/// pin that it never overrides a handler's deliberate choice.
Future<Response> _run(
  String path, {
  Map<String, String> headers = const {},
}) async {
  final handler = const Pipeline()
      .addMiddleware(securityHeadersMiddleware())
      .addHandler((_) async => Response.ok('body', headers: headers));
  return handler(Request('GET', Uri.parse('http://localhost$path')));
}

void main() {
  group('securityHeadersMiddleware cache-control', () {
    test('defaults API responses to private, no-store', () async {
      final response = await _run('/api/packages/foo');
      expect(response.headers['cache-control'], 'private, no-store');
    });

    test('defaults OAuth responses to private, no-store', () async {
      final response = await _run('/oauth/authorize');
      expect(response.headers['cache-control'], 'private, no-store');
    });

    test('defaults dartdoc to the same short TTL as the blob handler', () async {
      final response = await _run('/documentation/foo/latest/index.html');
      expect(response.headers['cache-control'], 'private, max-age=300');
    });

    test('never overrides a handler that set its own policy', () async {
      final response = await _run(
        '/api/packages/foo/versions/1.0.0/screenshots/0.png',
        headers: {'cache-control': 'private, max-age=31536000, immutable'},
      );
      expect(
        response.headers['cache-control'],
        'private, max-age=31536000, immutable',
      );
    });

    test('leaves the SPA shell and static assets cacheable', () async {
      // The SPA bundle is not secret and is fingerprinted; forcing
      // no-store here would defeat static asset caching for every visitor.
      final response = await _run('/_app/immutable/chunks/abc123.js');
      expect(response.headers['cache-control'], isNull);
    });

    test('does not emit a public directive anywhere by default', () async {
      for (final path in [
        '/api/search',
        '/oauth/token',
        '/documentation/foo/latest/',
      ]) {
        final response = await _run(path);
        expect(
          response.headers['cache-control'],
          isNot(contains('public')),
          reason: '$path must not be publicly cacheable while club is '
              'private-only',
        );
      }
    });
  });
}
