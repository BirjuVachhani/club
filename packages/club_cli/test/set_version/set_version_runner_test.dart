import 'package:club_cli/src/set_version/set_version_runner.dart';
import 'package:club_cli/src/util/exit_codes.dart';
import 'package:test/test.dart';

import 'set_version_test_utils.dart';

void main() {
  test(
    'selection changes only selected top-level version and all references',
    () async {
      final root = createWorkspace({
        'a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
        'b/pubspec.yaml': 'name: b\nversion: 0.1.0\n',
        'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a: ^0.1.0
  b: ^0.1.0
''',
      });
      final runner = SetVersionRunner(
        SetVersionOptions(version: '0.2.0', directory: root.path),
        selector: (packages, version) async => ['a'],
      );

      final code = await runner.run();

      expect(code, ExitCodes.success);
      expect(readManifest(root, 'a/pubspec.yaml'), contains('version: 0.2.0'));
      expect(readManifest(root, 'b/pubspec.yaml'), contains('version: 0.1.0'));
      final consumer = readManifest(root, 'consumer/pubspec.yaml');
      expect(consumer, contains('a: ^0.2.0'));
      expect(consumer, contains('b: ^0.1.0'));
    },
  );

  test('empty selection leaves files unchanged', () async {
    final root = createWorkspace({
      'a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
    });
    final runner = SetVersionRunner(
      SetVersionOptions(version: '0.2.0', directory: root.path),
      selector: (packages, version) async => [],
    );

    final code = await runner.run();

    expect(code, ExitCodes.success);
    expect(readManifest(root, 'a/pubspec.yaml'), contains('version: 0.1.0'));
  });
}
