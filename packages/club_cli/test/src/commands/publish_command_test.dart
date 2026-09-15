import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:club_cli/src/commands/publish_command.dart';
import 'package:club_cli/src/util/exit_codes.dart';
import 'package:test/test.dart';

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
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        await request.drain<void>();
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

    Future<ProcessResult> publish(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      [
        entrypoint,
        'publish',
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
