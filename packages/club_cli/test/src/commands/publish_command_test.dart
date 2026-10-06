import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:club_cli/src/commands/publish_command.dart';
import 'package:club_cli/src/util/exit_codes.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('yes defaults to false and does not imply force', () {
    final parser = PublishCommand().argParser;
    expect(parser.parse([])['yes'], isFalse);
    for (final flag in ['-y', '--yes']) {
      final args = parser.parse([flag]);
      expect(args['yes'], isTrue);
      expect(args['force'], isFalse);
    }
    final args = parser.parse(['-fy']);
    expect(args['yes'], isTrue);
    expect(args['force'], isTrue);
  });

  group('publish confirmations', () {
    late Directory root;
    late Directory package;
    late HttpServer server;
    late String serverUrl;
    late String entrypoint;
    var alreadyPublished = false;
    final finalized = <Uri>[];
    final publishedVersions = <String, List<String>>{};
    final lookupStatuses = <String, int>{};
    final requests = <String>[];
    final uploadedPubspecs = <YamlMap>[];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('club-publish-yes-test-');
      package = await Directory('${root.path}/package').create();
      await File('${package.path}/pubspec.yaml').writeAsString('''
name: yes_test_package
version: 1.0.0
description: A private package used to test publish confirmation handling.
environment:
  sdk: '>=3.0.0 <4.0.0'
''');
      await Directory('${package.path}/lib').create();
      await File('${package.path}/lib/yes_test_package.dart')
          .writeAsString('const value = 1;\n');
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:club_cli/club_cli.dart'),
      );
      entrypoint = File.fromUri(library!.resolve('../bin/club.dart')).path;
      alreadyPublished = false;
      finalized.clear();
      publishedVersions.clear();
      lookupStatuses.clear();
      requests.clear();
      uploadedPubspecs.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        requests.add(request.uri.path);
        if (request.uri.path == '/upload') {
          final body = await request.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          // ponytail: fixture uploads contain one archive part and no fields;
          // use a multipart parser if this harness gains more upload parts.
          final boundary = request.headers.contentType!.parameters['boundary']!;
          final framing = latin1.decode(body);
          final start = framing.indexOf('\r\n\r\n') + 4;
          final end = framing.lastIndexOf('\r\n--$boundary--');
          expect(
            start,
            greaterThan(3),
            reason: 'The archive needs multipart headers.',
          );
          expect(
            end,
            greaterThan(start),
            reason: 'The archive part must be complete.',
          );
          final reader = TarReader(
            Stream.value(body.sublist(start, end)).transform(gzip.decoder),
          );
          try {
            while (await reader.moveNext()) {
              if (reader.current.name == 'pubspec.yaml') {
                uploadedPubspecs.add(
                  loadYaml(
                    await utf8.decoder.bind(reader.current.contents).join(),
                  ) as YamlMap,
                );
              }
            }
          } finally {
            await reader.cancel();
          }
        } else {
          await request.drain<void>();
        }
        final response = request.response;
        response.headers.contentType = ContentType.json;
        switch (request.uri.path) {
          case '/api/packages/yes_test_package':
            final version = {
              'version': '1.0.0',
              'pubspec': {'name': 'yes_test_package', 'version': '1.0.0'},
            };
            response.write(
              jsonEncode({
                'name': 'yes_test_package',
                'latest': version,
                'versions': [if (alreadyPublished) version],
              }),
            );
          case '/api/packages/versions/new':
            response.write(
              jsonEncode({'url': '$serverUrl/upload', 'fields': {}}),
            );
          case '/upload':
            response.headers.contentType = ContentType.text;
            response.write('$serverUrl/finalize');
          case '/finalize':
            finalized.add(request.uri);
            response.write(
              jsonEncode({
                'success': {'message': 'Published.'},
              }),
            );
          case final path when path.startsWith('/api/packages/'):
            final name = request.uri.pathSegments.last;
            final status = lookupStatuses[name] ?? HttpStatus.ok;
            response.statusCode = status;
            if (status != HttpStatus.ok) {
              response.write(
                jsonEncode({
                  'error': {'message': 'Lookup failed ($status)'},
                }),
              );
            } else {
              final versions = [
                for (final version in publishedVersions[name] ?? <String>[])
                  {
                    'version': version,
                    'pubspec': {'name': name, 'version': version},
                  },
              ];
              response.write(
                jsonEncode({
                  'name': name,
                  'latest': versions.isEmpty
                      ? {
                          'version': '1.0.0',
                          'pubspec': {'name': name, 'version': '1.0.0'},
                        }
                      : versions.last,
                  'versions': versions,
                }),
              );
            }
          default:
            response.statusCode = HttpStatus.notFound;
            response.write(
              jsonEncode({
                'error': {'message': 'Not found'},
              }),
            );
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });

    Future<ProcessResult> publish(
      List<String> args, {
      String command = 'publish',
    }) => Process.run(
      Platform.resolvedExecutable,
      [
        entrypoint,
        command,
        '-C',
        package.path,
        '--server',
        serverUrl,
        ...args,
      ],
      environment: {
        'HOME': root.path,
        'USERPROFILE': root.path,
        'APPDATA': root.path,
        'CLUB_TOKEN': 'test-token',
        'CI': 'false',
        'CONTINUOUS_INTEGRATION': 'false',
        'BUILD_NUMBER': '',
        'NO_UPDATE_CHECK': '1',
      },
    );

    test('still refuses non-interactive publishing without consent', () async {
      final result = await publish(['--skip-validation']);
      expect(result.exitCode, ExitCodes.config, reason: '${result.stderr}');
      expect(
        '${result.stdout}${result.stderr}',
        contains('without --yes or --force'),
      );
      expect(finalized, isEmpty);
    });

    for (final flag in ['-y', '--yes']) {
      test('$flag publishes without setting the server force flag', () async {
        final result = await publish([flag, '--skip-validation']);
        expect(result.exitCode, ExitCodes.success, reason: '${result.stderr}');
        expect(finalized, hasLength(1));
        expect(finalized.single.queryParameters, isNot(contains('force')));
      });
    }

    test('yes alone refuses to overwrite an existing version', () async {
      alreadyPublished = true;
      final result = await publish(['-y', '--skip-validation']);
      expect(result.exitCode, ExitCodes.data, reason: '${result.stderr}');
      expect('${result.stdout}${result.stderr}', contains('already published'));
      expect(finalized, isEmpty);
    });

    test('yes combines with explicit force to overwrite', () async {
      alreadyPublished = true;
      final result = await publish(['-fy', '--skip-validation']);
      expect(result.exitCode, ExitCodes.success, reason: '${result.stderr}');
      expect(finalized, hasLength(1));
      expect(finalized.single.queryParameters['force'], 'true');
    });

    test('auto forwards yes to each package without forcing', () async {
      final result = await publish([
        '--auto',
        '-y',
        '--skip-validation',
        'yes_test_package',
      ]);
      expect(result.exitCode, ExitCodes.success, reason: '${result.stderr}');
      expect(finalized, hasLength(1));
      expect(finalized.single.queryParameters, isNot(contains('force')));
    });

    group('selected-only auto publish', () {
      Future<void> writePackage(
        String name, {
        String? dependency,
        bool dev = false,
      }) async {
        final directory = await Directory('${package.path}/$name/lib')
            .create(recursive: true);
        await File('${directory.parent.path}/pubspec.yaml').writeAsString(
          '''
name: $name
version: 0.2.0
description: A private package used to test selected-only publishing.
environment:
  sdk: '>=3.0.0 <4.0.0'
${dependency == null ? '' : '${dev ? 'dev_dependencies' : 'dependencies'}:\n  $dependency:\n    path: ../$dependency\n'}''',
        );
        await File('${directory.path}/$name.dart')
            .writeAsString('const value = 1;\n');
      }

      Future<ProcessResult> auto({
        List<String> targets = const ['b'],
        List<String> flags = const [],
      }) => publish([
        '--auto',
        '--yes',
        '--skip-validation',
        ...flags,
        ...targets,
      ]);

      setUp(() async {
        package = await Directory('${root.path}/workspace').create();
        await writePackage('a');
        await writePackage('b', dependency: 'a');
        publishedVersions['a'] = ['0.2.0'];
      });

      for (final mode in ['prompt', 'overwrite', 'skip', 'abort']) {
        test('$mode silently reuses unselected dependency', () async {
          final original = await File('${package.path}/b/pubspec.yaml')
              .readAsString();
          final result = await auto(
            flags: [if (mode != 'prompt') '--on-conflict=$mode'],
          );
          expect(
            result.exitCode,
            ExitCodes.success,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(uploadedPubspecs.map((p) => p['name']), ['b']);
          expect(uploadedPubspecs.single['dependencies']['a'], {
            'hosted': serverUrl,
            'version': '^0.2.0',
          });
          expect(finalized.single.queryParameters, isNot(contains('force')));
          expect(
            requests
                .where(
                  (p) =>
                      p.startsWith('/api/packages/') &&
                      p != '/api/packages/versions/new',
                )
                .toSet(),
            {
              '/api/packages/a',
              '/api/packages/b',
            },
          );
          expect(
            await File('${package.path}/b/pubspec.yaml').readAsString(),
            original,
          );
        });
      }

      for (final status in [HttpStatus.notFound, HttpStatus.ok]) {
        test(
          'missing dependency version ($status) fails before upload',
          () async {
            lookupStatuses['a'] = status;
            publishedVersions['a'] = ['0.1.0'];
            final result = await auto(flags: ['--on-conflict=overwrite']);
            final output = '${result.stdout}${result.stderr}';
            expect(result.exitCode, ExitCodes.data, reason: output);
            expect(output, contains('0.2.0'));
            expect(output, contains('not published'));
            expect(output, contains('Select a explicitly'));
            expect(requests, isNot(contains('/api/packages/versions/new')));
            expect(uploadedPubspecs, isEmpty);
            expect(finalized, isEmpty);
          },
        );
      }

      for (final status in [
        HttpStatus.unauthorized,
        HttpStatus.internalServerError,
      ]) {
        test(
          'dependency lookup $status fails verification before upload',
          () async {
            lookupStatuses['a'] = status;
            final result = await auto(flags: ['--on-conflict=overwrite']);
            final output = '${result.stdout}${result.stderr}';
            expect(result.exitCode, ExitCodes.unavailable, reason: output);
            expect(
              output,
              contains('Could not verify published versions of a'),
            );
            expect(output, isNot(contains('not published')));
            expect(requests, isNot(contains('/api/packages/versions/new')));
            expect(uploadedPubspecs, isEmpty);
            expect(finalized, isEmpty);
          },
        );
      }

      for (final exists in [false, true]) {
        test(
          'explicit selection ${exists ? 'overwrites' : 'publishes'} dependency',
          () async {
            publishedVersions['a'] = [if (exists) '0.2.0'];
            final result = await auto(
              targets: ['b', 'a'],
              flags: [if (exists) '--on-conflict=overwrite'],
            );
            expect(
              result.exitCode,
              ExitCodes.success,
              reason: '${result.stdout}\n${result.stderr}',
            );
            expect(uploadedPubspecs.map((p) => p['name']), ['a', 'b']);
            expect(
              finalized.first.queryParameters['force'],
              exists ? 'true' : null,
            );
            expect(finalized.last.queryParameters, isNot(contains('force')));
          },
        );
      }

      test('explicitly selected published dependency still requires conflict choice', () async {
        final result = await auto(targets: ['b', 'a']);
        expect(
          result.exitCode,
          ExitCodes.config,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          '${result.stdout}${result.stderr}',
          contains('Version conflicts'),
        );
        expect(uploadedPubspecs, isEmpty);
        expect(finalized, isEmpty);
      });

      test(
        'does not query unrelated or reused dependency transitive packages',
        () async {
          await writePackage('a', dependency: 'c');
          await writePackage('c');
          await writePackage('unrelated', dependency: 'missing');
          final result = await auto();
          expect(
            result.exitCode,
            ExitCodes.success,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(uploadedPubspecs.map((p) => p['name']), ['b']);
          expect(requests, isNot(contains('/api/packages/c')));
          expect(requests, isNot(contains('/api/packages/unrelated')));
          expect(requests, isNot(contains('/api/packages/missing')));
        },
      );

      test('dev dependencies are reused without selecting them', () async {
        await writePackage('b', dependency: 'a', dev: true);
        final result = await auto();
        expect(
          result.exitCode,
          ExitCodes.success,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(uploadedPubspecs.map((p) => p['name']), ['b']);
        expect(uploadedPubspecs.single['dev_dependencies']['a'], {
          'hosted': serverUrl,
          'version': '^0.2.0',
        });
      });

      test(
        'version override preserves unselected dependency local version',
        () async {
          final result = await auto(flags: ['--version=2.0.0']);
          expect(
            result.exitCode,
            ExitCodes.success,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(uploadedPubspecs.map((p) => p['name']), ['b']);
          expect(uploadedPubspecs.single['version'], '2.0.0');
          expect(uploadedPubspecs.single['dependencies']['a'], {
            'hosted': serverUrl,
            'version': '^0.2.0',
          });
        },
      );

      test(
        'prepare reuses unselected dependency without a conflict prompt',
        () async {
          final original = await File('${package.path}/a/pubspec.yaml')
              .readAsString();
          final result = await publish(['--force', 'b'], command: 'prepare');
          expect(
            result.exitCode,
            ExitCodes.success,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final prepared = loadYaml(
            await File('${package.path}/b/pubspec.yaml').readAsString(),
          );
          expect(prepared['dependencies']['a'], {
            'hosted': serverUrl,
            'version': '^0.2.0',
          });
          expect(
            await File('${package.path}/a/pubspec.yaml').readAsString(),
            original,
          );
          expect(uploadedPubspecs, isEmpty);
          expect(finalized, isEmpty);
        },
      );
    });

    test('yes accepts validator warnings', () async {
      final result = await publish(['-y']);
      expect(
        result.exitCode,
        ExitCodes.success,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(finalized, hasLength(1));
      expect(finalized.single.queryParameters, isNot(contains('force')));
    });

    test('yes does not bypass validator errors', () async {
      final pubspec = File('${package.path}/pubspec.yaml');
      await pubspec.writeAsString(
        (await pubspec.readAsString()).replaceFirst(
          RegExp(r'description:.*\n'),
          '',
        ),
      );
      final result = await publish(['-y']);
      expect(
        result.exitCode,
        ExitCodes.data,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(
        '${result.stdout}${result.stderr}',
        contains('missing a "description"'),
      );
      expect(finalized, isEmpty);
    });

    test('yes preserves dry-run warnings and never uploads', () async {
      final result = await publish(['-y', '--dry-run']);
      expect(
        result.exitCode,
        ExitCodes.data,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect('${result.stdout}${result.stderr}', contains('--ignore-warnings'));
      expect(finalized, isEmpty);
    });
  });
}
