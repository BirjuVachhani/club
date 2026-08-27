import 'package:club_cli/src/prepare/package_discovery.dart';
import 'package:club_cli/src/set_version/set_version_planner.dart';
import 'package:test/test.dart';

import 'set_version_test_utils.dart';

void main() {
  group('planSetVersion', () {
    test(
      'updates selected versions and hosted references in every section',
      () {
        final root = createWorkspace({
          'a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
          'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a: ^0.1.0
dev_dependencies:
  a:
    hosted: https://club.example.com
    version: ^0.1.0
dependency_overrides:
  a: any
''',
        });
        final packages = discoverPackages(root.path);

        final plan = planSetVersion(
          packages: packages,
          selectedPackageNames: {'a'},
          newVersion: '0.2.0',
        );

        expect(plan.versionChanges, 1);
        expect(plan.dependencyChanges, 3);
        expect(
          plan.packages
              .singleWhere((p) => p.package.name == 'consumer')
              .updateTopLevelVersion,
          isFalse,
        );
      },
    );

    test('recognizes a package named by a modern hosted descriptor', () {
      final root = createWorkspace({
        'a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
        'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
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

      final consumer = plan.packages.singleWhere(
        (package) => package.package.name == 'consumer',
      );
      expect(consumer.dependencyUpdates, hasLength(1));
      expect(consumer.dependencyUpdates.single.dependencyName, 'alias');
    });

    test('skips path git and sdk dependency descriptors', () {
      final root = createWorkspace({
        'a/pubspec.yaml': 'name: a\nversion: 0.1.0\n',
        'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a:
    path: ../a
dev_dependencies:
  a:
    git: https://example.com/a.git
dependency_overrides:
  a:
    sdk: flutter
''',
      });

      final plan = planSetVersion(
        packages: discoverPackages(root.path),
        selectedPackageNames: {'a'},
        newVersion: '0.2.0',
      );

      expect(plan.dependencyChanges, 0);
      expect(plan.skippedNonHostedReferences, 3);
    });

    test('does not plan already matching values or unselected references', () {
      final root = createWorkspace({
        'a/pubspec.yaml': 'name: a\nversion: 0.2.0\n',
        'b/pubspec.yaml': 'name: b\nversion: 0.1.0\n',
        'consumer/pubspec.yaml': '''
name: consumer
version: 1.0.0
dependencies:
  a: ^0.2.0
  b: ^0.1.0
''',
      });

      final plan = planSetVersion(
        packages: discoverPackages(root.path),
        selectedPackageNames: {'a'},
        newVersion: '0.2.0',
      );

      expect(plan.versionChanges, 0);
      expect(plan.dependencyChanges, 0);
    });
  });
}
