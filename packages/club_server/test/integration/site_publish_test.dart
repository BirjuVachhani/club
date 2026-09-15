import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:club_core/club_core.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:club_db/club_db.dart';
import 'package:club_server/src/api/pub_api.dart';
import 'package:club_server/src/api/admin_api.dart';
import 'package:club_server/src/api/package_admin_api.dart';
import 'package:club_server/src/middleware/public_package_access.dart';
import 'package:club_server/src/update/update_checker.dart';
import 'package:club_server/src/middleware/auth_middleware.dart';
import 'package:club_server/src/middleware/error_middleware.dart';
import 'package:club_server/src/sites/archive_validator.dart';
import 'package:club_server/src/sites/site_api.dart';
import 'package:club_server/src/config/app_config.dart';
import 'package:club_storage/club_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ClubDatabase db;
  late SqliteMetadataStore metadata;
  late PublishService publisher;
  late PubApi api;
  late FilesystemSiteArchiveStore siteStore;
  late Handler deleteHandler;
  late AuthService auth;
  late AppConfig config;
  var useAdminRoute = false;
  var failCleanup = false;
  Completer<void>? validationEntered;
  Completer<void>? resumeValidation;
  late FilesystemBlobStore blobs;
  late PackageService packageService;
  var counter = 0;
  var version = '1.0.0';
  const user = AuthenticatedUser(
    userId: 'user',
    email: 'test@example.test',
    displayName: 'Test',
    role: UserRole.admin,
    scopes: [],
    tokenKind: ApiTokenKind.pat,
    tokenId: 'token',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-publish-');
    db = await ClubDatabase.memory();
    await db.runMigrations();
    metadata = SqliteMetadataStore(db);
    await metadata.createUser(
      const UserCompanion(
        userId: 'user',
        email: 'test@example.test',
        passwordHash: 'unused',
        displayName: 'Test',
        role: UserRole.admin,
      ),
    );
    blobs = FilesystemBlobStore(rootPath: '${root.path}/blobs');
    await blobs.open();
    siteStore = FilesystemSiteArchiveStore(rootPath: '${root.path}/sites');
    await siteStore.open();
    publisher = PublishService(
      store: metadata,
      blobStore: blobs,
      searchIndex: SqliteSearchIndex(db),
      generateId: () => 'id${counter++}',
      tempDir: '${root.path}/uploads',
      siteStore: siteStore,
      validateSiteArchive: (file, limits) async {
        await validateSiteArchive(file, limits);
        validationEntered?.complete();
        await resumeValidation?.future;
      },
      extractArchive: (_) async => ArchiveContent(
        pubspecYaml: '',
        pubspecMap: {'name': 'test_package', 'version': version},
        readme: null,
        changelog: null,
        example: null,
        libraries: [],
      ),
    );
    final downloads = DownloadService(store: metadata);
    packageService = PackageService(
      store: metadata,
      downloadService: downloads,
      generateId: () => 'id${counter++}',
    );
    api = PubApi(
      packageService: packageService,
      publishService: publisher,
      blobStore: blobs,
      metadataStore: metadata,
      downloadService: downloads,
    );
    config = AppConfig(jwtSecret: 'x' * 32, sitesPath: siteStore.rootPath);
    auth = AuthService(
      store: metadata,
      hashPassword: (value) async => value,
      verifyPassword: (value, hash) async => value == hash,
      generateId: () => 'id${counter++}',
      generateTokenSecret: () => 'secret${counter++}',
    );
    final visibility = VisibilityService(
      store: metadata,
      settings: SqliteSettingsStore(db),
      generateId: () => 'id${counter++}',
      envEnabled: true,
    );
    final cleanup = _FailingSiteStore(siteStore, () => failCleanup);
    final ownerApi = PackageAdminApi(
      packageService: packageService,
      metadataStore: metadata,
      blobStore: blobs,
      siteStore: cleanup,
      publishService: publisher,
      visibilityService: visibility,
      packageGroupService: PackageGroupService(
        store: metadata,
        searchIndex: SqliteSearchIndex(db),
        packageService: packageService,
        generateId: () => 'id${counter++}',
      ),
    );
    final adminApi = AdminApi(
      authService: auth,
      metadataStore: metadata,
      blobStore: blobs,
      siteStore: cleanup,
      publishService: publisher,
      searchIndex: SqliteSearchIndex(db),
      serverUrl: Uri.parse('http://localhost'),
      config: config,
      startedAt: DateTime.now(),
      updateChecker: FakeUpdateChecker(),
      visibilityService: visibility,
    );
    deleteHandler = (request) => useAdminRoute
        ? adminApi.router.call(request)
        : ownerApi.router.call(request);
    failCleanup = false;
    validationEntered = null;
    resumeValidation = null;
    version = '1.0.0';
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<List<int>> archive(String text) async {
    final bytes = utf8.encode(text);
    return Stream.value(
          TarEntry(
            TarHeader(
              name: 'index.html',
              size: bytes.length,
              mode: 420,
              typeFlag: TypeFlag.reg,
            ),
            Stream.value(bytes),
          ),
        )
        .transform(tarWriter)
        .transform(gzip.encoder)
        .fold<List<int>>([], (a, b) => a..addAll(b));
  }

  Future<String> upload({
    Map<String, List<int>>? sites,
    Map<String, String> urls = const {},
    Map<String, String> labels = const {},
    bool badDigest = false,
    bool siteFirst = false,
    AuthenticatedUser actor = user,
  }) async {
    final start = await publisher.startUpload(
      'user',
      baseUrl: Uri.parse('http://localhost/'),
    );
    expect(start['sites_version'], 1);
    final id = (start['fields'] as Map)['upload_id'] as String;
    final parts = <String, List<int>>{
      'upload_id': utf8.encode(id),
      'file': [1, 2, 3],
    };
    if (sites != null || urls.isNotEmpty) {
      final manifest = <Map<String, Object>>[];
      var i = 0;
      for (final entry in (sites ?? <String, List<int>>{}).entries) {
        final part = 'site_${i++}';
        manifest.add({
          'name': entry.key,
          if (labels[entry.key] != null) 'label': labels[entry.key]!,
          'part': part,
          'length': entry.value.length,
          'sha256': badDigest
              ? '0' * 64
              : sha256.convert(entry.value).toString(),
        });
        parts[part] = entry.value;
      }
      manifest.addAll(
        urls.entries.map(
          (entry) => {
            'name': entry.key,
            'url': entry.value,
            if (labels[entry.key] != null) 'label': labels[entry.key]!,
          },
        ),
      );
      parts['sites_manifest'] = utf8.encode(
        jsonEncode({'version': 1, 'sites': manifest}),
      );
    }
    final body = <int>[];
    final entries = siteFirst ? parts.entries.toList().reversed : parts.entries;
    for (final part in entries) {
      body.addAll(
        utf8.encode(
          '--boundary\r\nContent-Disposition: form-data; name="${part.key}"\r\n\r\n',
        ),
      );
      body.addAll(part.value);
      body.addAll([13, 10]);
    }
    body.addAll(utf8.encode('--boundary--\r\n'));
    final response = await api.router.call(
      Request(
        'POST',
        Uri.parse('http://localhost/api/packages/versions/upload'),
        headers: {'content-type': 'multipart/form-data; boundary="boundary"'},
        body: body,
        context: {authContextKey: actor},
      ),
    );
    expect(response.statusCode, 302);
    return id;
  }

  Future<Response> delete() async => await deleteHandler(
    Request(
      'DELETE',
      Uri.parse(
        'http://localhost/api/${useAdminRoute ? 'admin/' : ''}packages/test_package',
      ),
      context: {authContextKey: user},
    ),
  );

  for (final adminRoute in [false, true]) {
    test(
      'delete/recreate does not expose private sites (admin=$adminRoute)',
      () async {
        useAdminRoute = adminRoute;
        await publisher.finalize(
          await upload(
            sites: {'demo': await archive('private')},
            urls: {'homepage': 'https://private.example.test'},
            labels: {'homepage': 'Private label'},
          ),
          'user',
        );
        // Simulate both journals left by an interrupted promotion.
        await Directory('${siteStore.rootPath}/test_package').rename(
          '${siteStore.rootPath}/test_package.backup',
        );
        await Directory(
          '${siteStore.rootPath}/test_package.candidate',
        ).create();
        expect((await delete()).statusCode, 200);
        await siteStore.open();
        await publisher.finalize(await upload(), 'user');
        await metadata.updatePackage(
          'test_package',
          const PackageCompanion(
            name: 'test_package',
            visibility: PackageVisibility.public,
          ),
        );
        await SqliteSettingsStore(db).setSetting('disable_sites', 'false');
        final handler = authMiddleware(
          auth,
          publicPackageAccess: PublicPackageAccess(
            store: metadata,
            isEnabled: () async => true,
          ),
        )(SiteApi(config, metadata, SqliteSettingsStore(db)).router.call);
        final response = await handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/packages/test_package/sites',
            ),
          ),
        );
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['sites'], isEmpty);
        expect(body['urls'], isEmpty);
        expect(body['labels'], isEmpty);
        expect(
          (await handler(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/packages/test_package/sites/demo/archive',
              ),
              headers: {'if-none-match': '*'},
            ),
          )).statusCode,
          404,
        );
      },
    );

    test(
      'cleanup failure retains package and releases lock (admin=$adminRoute)',
      () async {
        useAdminRoute = adminRoute;
        await publisher.finalize(
          await upload(sites: {'demo': await archive('private')}),
          'user',
        );
        failCleanup = true;
        await expectLater(delete(), throwsA(isA<FileSystemException>()));
        expect(await metadata.lookupPackage('test_package'), isNotNull);
        expect(await blobs.exists('test_package', '1.0.0'), isTrue);
        expect(
          await File(
            '${siteStore.rootPath}/test_package/demo/site.tar.gz',
          ).exists(),
          isTrue,
        );
        failCleanup = false;
        expect((await delete()).statusCode, 200);
      },
    );

    test('delete waits for in-flight publish (admin=$adminRoute)', () async {
      useAdminRoute = adminRoute;
      await publisher.finalize(await upload(), 'user');
      version = '1.1.0';
      validationEntered = Completer<void>();
      resumeValidation = Completer<void>();
      final write = publisher.finalize(
        await upload(sites: {'demo': await archive('private')}),
        'user',
      );
      await validationEntered!.future;
      var deleted = false;
      final deletion = delete().then((response) {
        deleted = true;
        return response;
      });
      await Future<void>.delayed(Duration.zero);
      expect(deleted, isFalse);
      resumeValidation!.complete();
      await write;
      validationEntered = null;
      resumeValidation = null;
      expect((await deletion).statusCode, 200);
      await publisher.finalize(await upload(), 'user');
      expect(
        await Directory('${siteStore.rootPath}/test_package').exists(),
        isFalse,
      );
    });
  }

  group('published package archives', () {
    test('encoded archive paths never expose another package', () async {
      await publisher.finalize(await upload(), 'user');
      await metadata.updatePackage(
        'test_package',
        const PackageCompanion(
          name: 'test_package',
          visibility: PackageVisibility.public,
        ),
      );
      await blobs.put('private_package', '1.0.0', Stream.value([4, 5, 6]));
      final token = await auth.createPersonalAccessToken(
        userId: 'user',
        name: 'Archive traversal regression',
      );
      final handler = errorMiddleware()(
        authMiddleware(
          auth,
          publicPackageAccess: PublicPackageAccess(
            store: metadata,
            isEnabled: () async => true,
          ),
        )(api.router.call),
      );
      for (final pathVersion in [
        '..%2fprivate_package%2f1.0.0',
        '..%2Fprivate_package%2F1.0.0',
        '..%5cprivate_package%5c1.0.0',
      ]) {
        final uri = Uri.parse(
          'http://localhost/api/archives/test_package-$pathVersion.tar.gz',
        );
        expect((await handler(Request('GET', uri))).statusCode, 401);
        expect(
          (await handler(
            Request(
              'GET',
              uri,
              headers: {'authorization': 'Bearer ${token.rawSecret}'},
            ),
          )).statusCode,
          404,
          reason: 'Even authenticated requests must reject decoded paths.',
        );
      }
      expect(
        (await handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/archives/unknown_package-1.0.0-beta.1.tar.gz',
            ),
          ),
        )).statusCode,
        401,
      );
      expect(
        (await handler(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/archives/test_package-9.9.9-beta.1.tar.gz',
            ),
          ),
        )).statusCode,
        404,
      );
    });

    for (final publishedVersion in [
      '12.0.7',
      '12.0.7+build.5',
      '12.0.7-beta.1',
      '12.0.7-beta-foo.1',
      '12.0.7-beta.1+build.5',
      '12.0.7+build-5',
    ]) {
      for (final anonymous in [false, true]) {
        test('$publishedVersion (anonymous=$anonymous)', () async {
          version = publishedVersion;
          await publisher.finalize(await upload(), 'user');
          expect(await blobs.exists('test_package', version), isTrue);

          var publicEnabled = true;
          final handler = errorMiddleware()(
            authMiddleware(
              auth,
              publicPackageAccess: PublicPackageAccess(
                store: metadata,
                isEnabled: () async => publicEnabled,
              ),
            )(api.router.call),
          );
          final canonical = Uri.parse(
            'http://localhost/api/archives/test_package-$version.tar.gz',
          );
          expect(
            (await handler(Request('GET', canonical))).statusCode,
            401,
            reason: 'Private archives must still require credentials.',
          );

          final headers = <String, String>{};
          if (anonymous) {
            await metadata.updatePackage(
              'test_package',
              const PackageCompanion(
                name: 'test_package',
                visibility: PackageVisibility.public,
              ),
            );
          } else {
            final token = await auth.createPersonalAccessToken(
              userId: 'user',
              name: 'Archive regression',
            );
            headers['authorization'] = 'Bearer ${token.rawSecret}';
          }
          final manifest = await handler(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/packages/test_package/versions/$version',
              ),
              headers: headers,
            ),
          );
          expect(manifest.statusCode, 200);
          final metadataJson = jsonDecode(await manifest.readAsString()) as Map;
          expect(metadataJson['archive_url'], canonical.toString());
          final archiveUrl = Uri.parse(metadataJson['archive_url'] as String);
          final paths = {
            archiveUrl.path,
            '/api/archives/test_package-${Uri.encodeComponent(version)}.tar.gz',
            '/packages/test_package/versions/$version.tar.gz',
            '/api/packages/test_package/versions/$version/archive.tar.gz',
          };
          for (final path in paths) {
            var response = await handler(
              Request(
                'GET',
                archiveUrl.resolve(path),
                headers: headers,
              ),
            );
            if (!path.startsWith('/api/archives/')) {
              expect(response.statusCode, 303);
              expect(response.headers['location'], archiveUrl.path);
              response = await handler(
                Request(
                  'GET',
                  archiveUrl.resolve(response.headers['location']!),
                  headers: headers,
                ),
              );
            }
            expect(response.statusCode, 200, reason: path);
            expect(response.headers['content-type'], 'application/gzip');
            expect(await response.read().expand((chunk) => chunk).toList(), [
              1,
              2,
              3,
            ]);
          }
          final head = await handler(
            Request('HEAD', archiveUrl, headers: headers),
          );
          expect(head.statusCode, 200);
          expect(await head.read().expand((chunk) => chunk).toList(), isEmpty);

          publicEnabled = false;
          expect(
            (await handler(Request('GET', archiveUrl))).statusCode,
            401,
            reason: 'Disabling public packages must also gate archives.',
          );
        });
      }
    }
  });

  test('multipart stores two sites only after package finalization', () async {
    final demo = await archive('demo');
    final docs = await archive('docs');
    final id = await upload(
      sites: {'demo': demo, 'docs': docs},
      siteFirst: true,
    );
    expect(await metadata.lookupPackage('test_package'), isNull);
    await publisher.finalize(id, 'user');
    expect(
      await File(
        '${root.path}/sites/test_package/demo/site.tar.gz',
      ).readAsBytes(),
      demo,
    );
    expect(
      await File(
        '${root.path}/sites/test_package/docs/site.tar.gz',
      ).readAsBytes(),
      docs,
    );
    expect(
      await Directory('${root.path}/uploads/$id.tar.gz.sites').exists(),
      isFalse,
    );
  });
  test('latest stable activation, force repeat, and explicit clear', () async {
    final old = await archive('old');
    final newer = await archive('new');
    await publisher.finalize(await upload(sites: {'demo': old}), 'user');
    final file = File('${root.path}/sites/test_package/demo/site.tar.gz');
    version = '0.9.0';
    expect(
      await publisher.finalize(await upload(sites: {'demo': newer}), 'user'),
      contains('not activated'),
    );
    expect(await file.readAsBytes(), old);
    version = '2.0.0-dev.1';
    await publisher.finalize(await upload(sites: {'demo': newer}), 'user');
    expect(await file.readAsBytes(), old);
    version = '1.1.0';
    await publisher.finalize(await upload(sites: {'demo': newer}), 'user');
    expect(await file.readAsBytes(), newer);
    await expectLater(
      publisher.finalize(await upload(sites: {'demo': old}), 'user'),
      throwsA(isA<PackageRejectedException>()),
    );
    await publisher.finalize(
      await upload(sites: {'demo': old}),
      'user',
      force: true,
    );
    expect(await file.readAsBytes(), old);
    await publisher.finalize(await upload(sites: {}), 'user', force: true);
    expect(await file.exists(), isFalse);
  });
  test('package-only publish leaves sites unchanged', () async {
    await publisher.finalize(
      await upload(sites: {'demo': await archive('old')}),
      'user',
    );
    version = '1.1.0';
    await publisher.finalize(await upload(), 'user');
    expect(
      await File('${root.path}/sites/test_package/demo/site.tar.gz').exists(),
      isTrue,
    );
  });
  test('bad digest aborts before package metadata', () async {
    await expectLater(
      upload(sites: {'demo': await archive('bad')}, badDigest: true),
      throwsA(isA<InvalidInputException>()),
    );
    expect(await metadata.lookupPackage('test_package'), isNull);
  });
  test(
    'malformed site fails finalization without publishing package',
    () async {
      final id = await upload(
        sites: {
          'demo': [1, 2, 3],
        },
      );
      await expectLater(publisher.finalize(id, 'user'), throwsA(anything));
      expect(await metadata.lookupPackage('test_package'), isNull);
    },
  );
  test(
    'real CLI builds two sites and aborts before upload on build failure',
    () async {
      var uploadStarts = 0;
      final server = await shelf_io.serve(
        (Request request) {
          if (request.url.path == 'api/packages/versions/new') uploadStarts++;
          return api.router.call(
            request.change(context: {authContextKey: user}),
          );
        },
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final project = Directory('${root.path}/fixture');
      await project.create();
      await File('${project.path}/pubspec.yaml').writeAsString(
        'name: test_package\nversion: 1.0.0\nenvironment:\n  sdk: ^3.11.0\n',
      );
      await File('${project.path}/club.yaml').writeAsString(
        'sites:\n  demo:\n    build: mkdir -p demo && printf demo > demo/index.html\n    output: demo\n'
        '  docs:\n    build: mkdir -p docs && printf docs > docs/index.html\n    output: docs\n',
      );
      final workspace = Directory.current.path.endsWith('club_server')
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final script = '$workspace/packages/club_cli/bin/club.dart';
      Future<ProcessResult> run({bool dryRun = false}) => Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          script,
          'publish',
          '--directory',
          project.path,
          '--server',
          'http://127.0.0.1:${server.port}',
          '--skip-validation',
          if (!dryRun) '--force',
          if (dryRun) '--dry-run',
        ],
        workingDirectory: workspace,
        environment: {'CLUB_TOKEN': 'test', 'CI': 'true', 'SHELL': '/bin/sh'},
      );
      final dry = await run(dryRun: true);
      expect(dry.exitCode, 0, reason: '${dry.stdout}\n${dry.stderr}');
      expect(uploadStarts, 0);
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(uploadStarts, 1);
      expect(
        await File('${root.path}/sites/test_package/demo/site.tar.gz').exists(),
        isTrue,
      );
      expect(
        await File('${root.path}/sites/test_package/docs/site.tar.gz').exists(),
        isTrue,
      );
      await File('${project.path}/club.yaml').writeAsString(
        'sites:\n  demo:\n    output: demo\n  docs:\n    build: false\n    output: docs\n'
            .replaceFirst('build: false', 'build: "false"'),
      );
      final failed = await run();
      expect(failed.exitCode, isNot(0));
      expect(
        uploadStarts,
        1,
        reason: 'A broken build must not start another upload.',
      );
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'wrong upload owner is rejected before staged files are associated',
    () async {
      const other = AuthenticatedUser(
        userId: 'other',
        email: 'other@example.test',
        displayName: 'Other',
        role: UserRole.admin,
        scopes: [],
        tokenKind: ApiTokenKind.pat,
        tokenId: 'other',
      );
      await expectLater(
        upload(sites: {'demo': await archive('demo')}, actor: other),
        throwsA(isA<ForbiddenException>()),
      );
      expect(await metadata.lookupPackage('test_package'), isNull);
    },
  );

  test('expired and duplicate receives are rejected', () async {
    final id = await upload();
    final request = Request(
      'POST',
      Uri.parse('http://localhost/api/packages/versions/upload?upload_id=$id'),
      body: [9],
      context: {authContextKey: user},
    );
    await expectLater(
      api.router.call(request),
      throwsA(isA<InvalidInputException>()),
    );
    await metadata.createUploadSession(
      UploadSessionCompanion(
        id: 'expired',
        userId: 'user',
        tempPath: '${root.path}/uploads/expired.tar.gz',
        expiresAt: DateTime.utc(2000),
      ),
    );
    await expectLater(
      api.router.call(
        Request(
          'POST',
          Uri.parse(
            'http://localhost/api/packages/versions/upload?upload_id=expired',
          ),
          body: [9],
          context: {authContextKey: user},
        ),
      ),
      throwsA(isA<InvalidInputException>()),
    );
  });

  test('expired site staging is removed by cleanup', () async {
    final staged = Directory('${root.path}/uploads/expired.tar.gz.sites');
    await staged.create(recursive: true);
    await File('${staged.path}/site_0').writeAsString('orphan');
    await metadata.createUploadSession(
      UploadSessionCompanion(
        id: 'expired',
        userId: 'user',
        tempPath: '${root.path}/uploads/expired.tar.gz',
        expiresAt: DateTime.utc(2000),
      ),
    );
    await publisher.cleanupExpiredSessions();
    expect(await staged.exists(), isFalse);
  });
  test(
    'mixed URL and archive targets publish labels without uploading URL bytes',
    () async {
      final id = await upload(
        sites: {'demo': await archive('demo')},
        urls: {'homepage': 'https://google.com'},
        labels: {'demo': 'Live demo', 'homepage': 'Website'},
      );
      await publisher.finalize(id, 'user');
      final sites = SiteApi(
        AppConfig(jwtSecret: 'x' * 32, sitesPath: '${root.path}/sites'),
        metadata,
        SqliteSettingsStore(db),
      );
      final denied = await sites.list(
        Request('GET', Uri.parse('http://localhost/')),
        'test_package',
      );
      expect(denied.statusCode, 403);
      await SqliteSettingsStore(db).setSetting('disable_sites', 'false');
      final response = await sites.list(
        Request('GET', Uri.parse('http://localhost/')),
        'test_package',
      );
      final data = jsonDecode(await response.readAsString()) as Map;
      expect(data['sites'], ['demo', 'homepage']);
      expect(data['labels'], {'demo': 'Live demo', 'homepage': 'Website'});
      expect(data['urls'], {'homepage': 'https://google.com'});
      expect(
        await File(
          '${root.path}/sites/test_package/homepage/site.tar.gz',
        ).exists(),
        isFalse,
      );
    },
  );
}

class _FailingSiteStore implements SiteArchiveStore {
  _FailingSiteStore(this.inner, this.shouldFail);
  final SiteArchiveStore inner;
  final bool Function() shouldFail;
  @override
  Future<void> open() => inner.open();
  @override
  Future<void> replace(String package, String source, List<SiteUpload> sites) =>
      inner.replace(package, source, sites);
  @override
  Future<void> deletePackage(String package) {
    if (shouldFail()) throw const FileSystemException('cleanup failed');
    return inner.deletePackage(package);
  }
}
