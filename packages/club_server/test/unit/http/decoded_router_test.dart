import 'package:club_server/src/http/decoded_router.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// These tests guard against the regression that prompted the creation of
/// [DecodedRouter]: shelf_router passes raw (URL-encoded) path captures to
/// handlers, so a `<version>` param like `1.0.0+1` would arrive as
/// `1.0.0%2B1` and silently fail every exact-match DB lookup downstream.
///
/// If these fail, every versioned API endpoint (scoring, rescore,
/// archive download, version metadata, …) is broken for any package
/// with build-metadata in its version. Fix the decoder before shipping.
void main() {
  Future<Response> send(
    DecodedRouter router,
    String path, {
    String method = 'GET',
  }) {
    return Future.value(
      router.call(Request(method, Uri.parse('http://x$path'))),
    );
  }

  group('DecodedRouter', () {
    test('decodes %2B in path parameters before handler sees them', () async {
      String? captured;
      final router = DecodedRouter()
        ..get('/api/packages/<package>/versions/<version>', (
          Request _,
          String package,
          String version,
        ) {
          captured = '$package|$version';
          return Response.ok('');
        });

      final res = await send(
        router,
        '/api/packages/provider/versions/6.1.5%2B1',
      );

      expect(res.statusCode, 200);
      expect(captured, 'provider|6.1.5+1');
    });

    test('decodes %20 (space) in path parameters', () async {
      String? captured;
      final router = DecodedRouter()
        ..get('/packages/<name>', (Request _, String name) {
          captured = name;
          return Response.ok('');
        });

      await send(router, '/packages/hello%20world');
      expect(captured, 'hello world');
    });

    test('leaves unencoded ASCII untouched', () async {
      String? captured;
      final router = DecodedRouter()
        ..get('/packages/<name>', (Request _, String name) {
          captured = name;
          return Response.ok('');
        });

      await send(router, '/packages/provider');
      expect(captured, 'provider');
    });

    test('falls through malformed percent-encoding without raising', () async {
      // Uri.decodeComponent throws on `%5` (incomplete escape). We catch
      // that so the handler can return a clean 404 instead of a 500.
      String? captured;
      final router = DecodedRouter()
        ..get('/packages/<name>', (Request _, String name) {
          captured = name;
          return Response.ok('');
        });

      final res = await send(router, '/packages/bad%5');
      expect(res.statusCode, 200);
      expect(captured, 'bad%5');
    });

    test('decodes every positional param on multi-param routes', () async {
      String? captured;
      final router = DecodedRouter()
        ..get('/<a>/<b>/<c>', (Request _, String a, String b, String c) {
          captured = '$a|$b|$c';
          return Response.ok('');
        });

      await send(router, '/foo/1.0.0%2B1/bar%20baz');
      expect(captured, 'foo|1.0.0+1|bar baz');
    });

    test('post/put/delete/patch all go through the wrapper', () async {
      final captured = <String, String>{};
      final router = DecodedRouter()
        ..post('/p/<v>', (Request _, String v) {
          captured['post'] = v;
          return Response.ok('');
        })
        ..put('/p/<v>', (Request _, String v) {
          captured['put'] = v;
          return Response.ok('');
        })
        ..delete('/p/<v>', (Request _, String v) {
          captured['delete'] = v;
          return Response.ok('');
        })
        ..patch('/p/<v>', (Request _, String v) {
          captured['patch'] = v;
          return Response.ok('');
        });

      for (final m in ['POST', 'PUT', 'DELETE', 'PATCH']) {
        await send(router, '/p/1.0.0%2B1', method: m);
      }
      expect(captured, {
        'post': '1.0.0+1',
        'put': '1.0.0+1',
        'delete': '1.0.0+1',
        'patch': '1.0.0+1',
      });
    });
  });
}
