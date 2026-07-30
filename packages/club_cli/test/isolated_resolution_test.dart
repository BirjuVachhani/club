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
}
