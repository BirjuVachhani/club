import 'dart:io';
import 'dart:convert';
import 'package:club_server/src/middleware/auth_middleware.dart';
import 'package:club_server/src/api/setup_api.dart';
import 'package:club_core/club_core.dart';
import 'package:club_db/club_db.dart';
import 'package:club_server/src/config/app_config.dart';
import 'package:club_server/src/sites/site_api.dart';
import 'package:club_server/src/sites/runner_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _UnusedAuthService implements AuthService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('public startup status exposes the live sites setting', () async {
    final db = await ClubDatabase.memory();
    addTearDown(db.close);
    await db.runMigrations();
    final settings = SqliteSettingsStore(db);
    final api = SetupApi(
      authService: _UnusedAuthService(),
      metadataStore: SqliteMetadataStore(db),
      settingsStore: settings,
    );
    final request = Request(
      'GET',
      Uri.parse('http://localhost/api/setup/status'),
    );
    for (final disabled in [false, true, false]) {
      if (disabled || await settings.getSetting('disable_sites') != null) {
        await settings.setSetting('disable_sites', disabled.toString());
      }
      final response = await api.router.call(request);
      expect(response.statusCode, 200);
      expect(response.headers['cache-control'], 'no-store');
      expect(
        (jsonDecode(await response.readAsString()) as Map)['disableSites'],
        disabled,
      );
    }
  });
  test('stable archive URL returns 304 until bytes change', () async {
    final root = await Directory.systemTemp.createTemp('site-api-');
    final db = await ClubDatabase.memory();
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.runMigrations();
    final store = SqliteMetadataStore(db);
    await store.createPackage(const PackageCompanion(name: 'demo_pkg'));
    final file = File('${root.path}/demo_pkg/demo/site.tar.gz');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    final api = SiteApi(
      AppConfig(jwtSecret: 'x' * 32, sitesPath: root.path),
      store,
      SqliteSettingsStore(db),
    );
    Request request([String? etag]) => Request(
      'GET',
      Uri.parse('http://localhost/api/packages/demo_pkg/sites/demo/archive'),
      headers: {'if-none-match': ?etag},
    );
    final first = await api.router.call(request());
    expect(first.statusCode, 200);
    await first.read().drain<void>();
    final etag = first.headers['etag']!;
    final second = await api.router.call(request(etag));
    expect(second.statusCode, 304);
    expect(await second.readAsString(), '');
    expect(second.headers['cache-control'], 'private, no-cache');
    await file.writeAsBytes([4, 5, 6]);
    final third = await api.router.call(request(etag));
    expect(third.statusCode, 200);
    expect(third.headers['etag'], isNot(etag));
    await third.read().drain<void>();
    final redirects = File('${root.path}/demo_pkg/homepage/redirect.json');
    await redirects.parent.create(recursive: true);
    await redirects.writeAsString(jsonEncode({'url': 'https://example.com'}));
    final listing = Request(
      'GET',
      Uri.parse('http://localhost/api/packages/demo_pkg/sites'),
    );
    final before = await api.router.call(listing);
    expect((jsonDecode(await before.readAsString()) as Map)['urls'], {
      'homepage': 'https://example.com',
    });
    await SqliteSettingsStore(db).setSetting('disable_sites', 'true');
    for (final req in [
      listing,
      request(),
      request(etag),
      request('*'),
      request('W/$etag'),
    ]) {
      final denied = await api.router.call(req);
      expect(denied.statusCode, 403);
      expect(denied.headers['cache-control'], 'no-store');
      expect(denied.headers['etag'], isNull);
      expect(
        (jsonDecode(await denied.readAsString()) as Map)['error']['code'],
        'sites_disabled',
      );
    }
    await SqliteSettingsStore(db).setSetting('disable_sites', 'false');
    final restored = await api.router.call(listing);
    expect((jsonDecode(await restored.readAsString()) as Map)['sites'], [
      'demo',
      'homepage',
    ]);
    final restoredArchive = await api.router.call(
      request(third.headers['etag']),
    );
    expect(restoredArchive.statusCode, 304);
    final bad = await api.archive(request(), '../demo_pkg', 'demo');
    expect(bad.statusCode, 404);
  });
  test(
    'site settings default off, validate booleans and require admin',
    () async {
      final db = await ClubDatabase.memory();
      addTearDown(db.close);
      await db.runMigrations();
      final settings = SqliteSettingsStore(db);
      final api = SiteApi(
        AppConfig(jwtSecret: 'x' * 32),
        SqliteMetadataStore(db),
        settings,
      );
      Request request(String method, {UserRole? role, Object? body}) => Request(
        method,
        Uri.parse('http://localhost/api/admin/sites/settings'),
        body: body == null ? null : jsonEncode(body),
        context: {
          if (role != null)
            authContextKey: AuthenticatedUser(
              userId: 'admin',
              email: 'admin@example.com',
              displayName: 'Admin',
              role: role,
              scopes: const [],
              tokenKind: ApiTokenKind.session,
              tokenId: 'session',
            ),
        },
      );
      final initial = await api.router.call(
        request('GET', role: UserRole.admin),
      );
      expect(jsonDecode(await initial.readAsString()), {'disableSites': false});
      for (final method in ['GET', 'PUT']) {
        await expectLater(
          () => api.router.call(request(method, body: {'disableSites': true})),
          throwsA(isA<AuthException>()),
        );
        for (final role in [UserRole.viewer, UserRole.member]) {
          await expectLater(
            () => api.router.call(
              request(method, role: role, body: {'disableSites': true}),
            ),
            throwsA(isA<ForbiddenException>()),
          );
        }
      }
      for (final body in [
        {},
        {'disableSites': 'true'},
        {'disableSites': null},
        [],
      ]) {
        await expectLater(
          () =>
              api.router.call(request('PUT', role: UserRole.admin, body: body)),
          throwsA(isA<InvalidInputException>()),
        );
      }
      expect(await settings.getSetting('disable_sites'), isNull);
      for (final role in [UserRole.admin, UserRole.owner]) {
        final response = await api.router.call(
          request('PUT', role: role, body: {'disableSites': true}),
        );
        expect(jsonDecode(await response.readAsString()), {
          'disableSites': true,
        });
        expect(
          await SqliteSettingsStore(db).getSetting('disable_sites'),
          'true',
        );
      }
      final restored = await api.router.call(
        request('PUT', role: UserRole.admin, body: {'disableSites': false}),
      );
      expect(jsonDecode(await restored.readAsString()), {
        'disableSites': false,
      });
    },
  );
  test('runner never serves APIs or arbitrary paths', () async {
    final root = await Directory.systemTemp.createTemp('runner-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/index.html').writeAsString('runner');
    final handler = siteRunnerHandler(root.path);
    expect(
      (await handler(
        Request('GET', Uri.parse('http://runner/api/auth/me')),
      )).statusCode,
      404,
    );
    expect(
      (await handler(Request('GET', Uri.parse('http://runner/')))).statusCode,
      200,
    );
  });
}
