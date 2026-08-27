import 'dart:io';

import 'package:club_cli/src/prepare/package_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a throwaway workspace with one directory per entry in [packages],
/// keyed by name with the pubspec `version:` as the value (null writes a
/// pubspec with no version field).
Directory workspaceWith(Map<String, String?> packages) {
  final root = Directory.systemTemp.createTempSync('club-discovery-test-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  packages.forEach((name, version) {
    final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
      version == null
          ? 'name: $name\nenvironment:\n  sdk: ^3.11.0\n'
          : 'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.11.0\n',
    );
  });
  return root;
}

void main() {
  group('discoverPackages versions', () {
    test('without options, versions come from the pubspecs', () {
      final root = workspaceWith({'pkg_a': '1.2.0', 'pkg_b': '0.4.1'});
      final found = discoverPackages(root.path);
      expect(found['pkg_a']!.version, '1.2.0');
      expect(found['pkg_b']!.version, '0.4.1');
    });

    test('versionSuffix makes every package a prerelease of itself', () {
      final root = workspaceWith({'pkg_a': '1.2.0', 'pkg_b': '0.4.1'});
      final found = discoverPackages(root.path, versionSuffix: 'pr7');
      expect(found['pkg_a']!.version, '1.2.0-pr7');
      expect(found['pkg_b']!.version, '0.4.1-pr7');
    });

    test('versionSuffix preserves an existing prerelease and build', () {
      final root = workspaceWith({'pkg_a': '1.2.0-dev.3', 'pkg_b': '2.0.0+5'});
      final found = discoverPackages(root.path, versionSuffix: 'pr7');
      expect(found['pkg_a']!.version, '1.2.0-dev.3.pr7');
      expect(found['pkg_b']!.version, '2.0.0-pr7+5');
    });

    test('versionOverride replaces every version outright', () {
      final root = workspaceWith({'pkg_a': '1.2.0', 'pkg_b': '0.4.1'});
      final found = discoverPackages(root.path, versionOverride: '3.0.0');
      expect(found['pkg_a']!.version, '3.0.0');
      expect(found['pkg_b']!.version, '3.0.0');
    });

    test('versionOverride wins over versionSuffix, with no suffix added', () {
      final root = workspaceWith({'pkg_a': '1.2.0'});
      final found = discoverPackages(
        root.path,
        versionSuffix: 'pr7',
        versionOverride: '3.0.0',
      );
      expect(found['pkg_a']!.version, '3.0.0');
    });

    test('the pubspec on disk is never rewritten', () {
      final root = workspaceWith({'pkg_a': '1.2.0'});
      discoverPackages(root.path, versionOverride: '3.0.0');
      final onDisk = File(
        p.join(root.path, 'pkg_a', 'pubspec.yaml'),
      ).readAsStringSync();
      expect(onDisk, contains('version: 1.2.0'));
      expect(onDisk, isNot(contains('3.0.0')));
    });

    test('a package with no version is left alone by versionSuffix', () {
      // Nothing to derive a prerelease from; the planner reports the
      // missing version later with a better message than a crash here.
      final root = workspaceWith({'pkg_a': null});
      final found = discoverPackages(root.path, versionSuffix: 'pr7');
      expect(found['pkg_a']!.version, isNull);
    });

    test('versionOverride still applies to a package with no version', () {
      final root = workspaceWith({'pkg_a': null});
      final found = discoverPackages(root.path, versionOverride: '3.0.0');
      expect(found['pkg_a']!.version, '3.0.0');
    });
  });
  group('discoverPackages manifest names', () {
    test('discovers pubspec.yml and records its exact path', () {
      final root = Directory.systemTemp.createTempSync('club-yml-test-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final packageDir = Directory(p.join(root.path, 'pkg'))
        ..createSync(recursive: true);
      final manifest = File(p.join(packageDir.path, 'pubspec.yml'))
        ..writeAsStringSync('name: pkg\nversion: 1.0.0\n');

      final found = discoverPackages(root.path);

      expect(found['pkg']!.pubspecPath, p.canonicalize(manifest.path));
    });

    test('rejects directories containing both manifest filenames', () {
      final root = Directory.systemTemp.createTempSync(
        'club-both-pubspec-test-',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: pkg\nversion: 1.0.0\n');
      File(
        p.join(root.path, 'pubspec.yml'),
      ).writeAsStringSync('name: pkg\nversion: 1.0.0\n');

      expect(
        () => discoverPackages(root.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('does not include workspace umbrella manifests', () {
      final root = Directory.systemTemp.createTempSync('club-workspace-test-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
        'name: workspace_root\nworkspace:\n  - packages/pkg\n',
      );
      final packageDir = Directory(p.join(root.path, 'packages', 'pkg'))
        ..createSync(recursive: true);
      File(
        p.join(packageDir.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: pkg\nversion: 1.0.0\n');

      final found = discoverPackages(root.path);

      expect(found.keys, ['pkg']);
    });
  });
}
