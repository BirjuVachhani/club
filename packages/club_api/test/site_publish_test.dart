import 'dart:convert';
import 'dart:io';

import 'package:club_api/club_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('unsupported server is rejected before posting package bytes', () async {
    var calls = 0;
    final client = ClubClient(
      serverUrl: Uri.parse('http://localhost/'),
      token: 'test',
      httpClient: MockClient((request) async {
        calls++;
        expect(request.method, 'GET');
        return http.Response(
          jsonEncode({'url': 'http://localhost/upload', 'fields': {}}),
          200,
        );
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.publish(Stream.value([1]), length: 1, sites: []),
      throwsFormatException,
    );
    expect(calls, 1);
  });
  test(
    'posts package and named archive with manifest then finalizes',
    () async {
      final root = await Directory.systemTemp.createTemp('sdk-site-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        '${root.path}/site.tar.gz',
      ).writeAsString('site bytes');
      var calls = 0;
      final client = ClubClient(
        serverUrl: Uri.parse('http://localhost/'),
        token: 'test',
        httpClient: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              jsonEncode({
                'url': 'http://localhost/upload',
                'fields': {'upload_id': 'id'},
                'sites_version': 1,
              }),
              200,
            );
          }
          if (calls == 2) {
            expect(request.method, 'POST');
            expect(request.body, contains('name="file"'));
            expect(request.body, contains('name="site_0"'));
            expect(request.body, contains('name="sites_manifest"'));
            expect(request.body, contains('"name":"demo"'));
            return http.Response('', 302, headers: {'location': '/finish'});
          }
          expect(request.url.queryParameters['force'], 'true');
          return http.Response(
            jsonEncode({
              'success': {'message': 'published'},
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      expect(
        await client.publish(
          Stream.value([1, 2]),
          length: 2,
          force: true,
          sites: [SiteAttachment(name: 'demo', file: file)],
        ),
        'published',
      );
      expect(calls, 3);
    },
  );
}
