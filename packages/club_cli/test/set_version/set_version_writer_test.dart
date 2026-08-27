import 'package:club_cli/src/prepare/package_discovery.dart';
import 'package:club_cli/src/set_version/set_version_planner.dart';
import 'package:club_cli/src/set_version/set_version_writer.dart';
import 'package:test/test.dart';

import 'set_version_test_utils.dart';

void main() {
  test('preserves declaration shapes comments and hosted metadata', () {
    final root = createWorkspace({
      'a/pubspec.yml': 'name: a\n# Package version\nversion: 0.1.0\n',
      'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a: ^0.1.0 # shorthand
  alias:
    hosted:
      name: a
      url: https://club.example.com
    version: ^0.1.0
''',
    });
    final plan = planSetVersion(
      packages: discoverPackages(root.path),
      selectedPackageNames: {'a'},
      newVersion: '0.2.0',
    );

    final result = applySetVersionPlan(plan);

    expect(result.filesWritten, 2);
    expect(readManifest(root, 'a/pubspec.yml'), contains('# Package version'));
    expect(readManifest(root, 'a/pubspec.yml'), contains('version: 0.2.0'));
    final consumer = readManifest(root, 'consumer/pubspec.yaml');
    expect(consumer, contains('a: ^0.2.0 # shorthand'));
    expect(consumer, contains('name: a'));
    expect(consumer, contains('url: https://club.example.com'));
    expect(consumer, contains('version: ^0.2.0'));
  });

  test('adds missing top-level and hosted versions', () {
    final root = createWorkspace({
      'a/pubspec.yaml': 'name: a\n',
      'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a:
    hosted: https://club.example.com
''',
    });
    final plan = planSetVersion(
      packages: discoverPackages(root.path),
      selectedPackageNames: {'a'},
      newVersion: '0.2.0',
    );

    applySetVersionPlan(plan);

    expect(readManifest(root, 'a/pubspec.yaml'), contains('version: 0.2.0'));
    expect(
      readManifest(root, 'consumer/pubspec.yaml'),
      contains('version: ^0.2.0'),
    );
  });

  test('does not write no-op manifests', () {
    final root = createWorkspace({
      'a/pubspec.yaml': 'name: a\nversion: 0.2.0\n',
    });
    final plan = planSetVersion(
      packages: discoverPackages(root.path),
      selectedPackageNames: {'a'},
      newVersion: '0.2.0',
    );

    final result = applySetVersionPlan(plan);

    expect(result.filesWritten, 0);
  });
}
