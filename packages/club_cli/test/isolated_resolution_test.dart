import 'dart:io';

import 'package:club_cli/src/publish/isolated_resolution.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('club-strip-test-');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String write(String content) {
    final path = p.join(tmp.path, 'pubspec.yaml');
    File(path).writeAsStringSync(content);
    return path;
  }

  group('stripWorkspaceMarkers', () {
    test('removes resolution: workspace and reports the change', () {
      final path = write('''
name: auth_kit
version: 0.1.0

resolution: workspace

environment:
  sdk: ^3.12.0

dependencies:
  flutter:
    sdk: flutter
''');

      expect(stripWorkspaceMarkers(path), isTrue);

      final result = File(path).readAsStringSync();
      expect(result, isNot(contains('resolution:')));

      // Everything else survives, and the file still parses.
      final parsed = Pubspec.parse(result);
      expect(parsed.name, 'auth_kit');
      expect(parsed.version.toString(), '0.1.0');
      expect(parsed.resolution, isNull);
      expect(parsed.dependencies.keys, contains('flutter'));
    });

    test('removes a workspace: member list', () {
      final path = write('''
name: dream_council
version: 1.0.0

environment:
  sdk: ^3.12.0

workspace:
  - packages/auth_kit
  - packages/firebase_auth_kit
''');

      expect(stripWorkspaceMarkers(path), isTrue);

      final parsed = Pubspec.parse(File(path).readAsStringSync());
      expect(parsed.workspace, anyOf(isNull, isEmpty));
      expect(parsed.name, 'dream_council');
    });

    test('is a no-op when neither marker is present', () {
      const original = '''
name: club_cli
version: 0.4.0

environment:
  sdk: ^3.11.0

dependencies:
  path: ^1.9.1
''';
      final path = write(original);

      expect(stripWorkspaceMarkers(path), isFalse);
      expect(File(path).readAsStringSync(), original);
    });

    test('returns false for a missing pubspec instead of throwing', () {
      expect(
        stripWorkspaceMarkers(p.join(tmp.path, 'nope', 'pubspec.yaml')),
        isFalse,
      );
    });
  });

  group('pruneNestedPackages', () {
    /// Creates `<tmp>/<rel>/pubspec.yaml` plus one Dart file beside it.
    void nestedPackage(String rel, String name) {
      final dir = Directory(p.join(tmp.path, rel, 'lib'))
        ..createSync(recursive: true);
      File(p.join(dir.path, '$name.dart')).writeAsStringSync('// $name\n');
      File(p.join(tmp.path, rel, 'pubspec.yaml')).writeAsStringSync(
        'name: $name\nversion: 1.0.0\nresolution: workspace\n',
      );
    }

    setUp(() {
      write('name: host\nversion: 1.0.0\n');
      Directory(p.join(tmp.path, 'lib')).createSync(recursive: true);
      File(p.join(tmp.path, 'lib', 'host.dart')).writeAsStringSync('// host\n');
    });

    test('removes an example package and reports it', () {
      nestedPackage('example', 'host_example');

      expect(pruneNestedPackages(tmp), ['example']);
      expect(Directory(p.join(tmp.path, 'example')).existsSync(), isFalse);
    });

    test('leaves the package being published intact', () {
      nestedPackage('example', 'host_example');
      pruneNestedPackages(tmp);

      expect(File(p.join(tmp.path, 'pubspec.yaml')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'lib', 'host.dart')).existsSync(), isTrue);
    });

    test('removes a nested package at any depth', () {
      nestedPackage(p.join('test', 'fixtures', 'sample'), 'sample_fixture');

      expect(pruneNestedPackages(tmp), [p.join('test', 'fixtures', 'sample')]);
      expect(
        Directory(p.join(tmp.path, 'test', 'fixtures', 'sample')).existsSync(),
        isFalse,
      );
      // The intermediate directories are not packages, so they survive.
      expect(
        Directory(p.join(tmp.path, 'test', 'fixtures')).existsSync(),
        isTrue,
      );
    });

    test('reports every nested package, sorted', () {
      nestedPackage('example', 'host_example');
      nestedPackage('tool_pkg', 'host_tool');

      expect(pruneNestedPackages(tmp), ['example', 'tool_pkg']);
    });

    test('does not descend into a package it already removed', () {
      nestedPackage('example', 'host_example');
      nestedPackage(p.join('example', 'inner'), 'host_example_inner');

      // Only the outer package is reported; the inner one went with it.
      expect(pruneNestedPackages(tmp), ['example']);
    });

    test('returns empty for a package with no nested packages', () {
      expect(pruneNestedPackages(tmp), isEmpty);
      expect(File(p.join(tmp.path, 'lib', 'host.dart')).existsSync(), isTrue);
    });

    test('ignores .dart_tool even though it can contain a pubspec', () {
      final dartTool = Directory(p.join(tmp.path, '.dart_tool'))
        ..createSync(recursive: true);
      File(p.join(dartTool.path, 'pubspec.yaml'))
          .writeAsStringSync('name: leftover\n');

      expect(pruneNestedPackages(tmp), isEmpty);
      expect(dartTool.existsSync(), isTrue);
    });
  });
}
