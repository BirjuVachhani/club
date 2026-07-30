import 'package:club_cli/src/upgrade/install_method.dart';
import 'package:test/test.dart';

void main() {
  InstallLocation classify(
    String exe, {
    String? scriptPath,
    String version = '0.4.1',
    bool windows = false,
  }) =>
      classifyInstall(
        resolvedExecutable: exe,
        scriptPath: scriptPath,
        runningVersion: version,
        isWindows: windows,
      );

  group('script installs', () {
    test('standalone binary from install.sh', () {
      final r = classify('/Users/x/.local/bin/club');
      expect(r.method, InstallMethod.scriptStandalone);
      expect(r.destDir, '/Users/x/.local/bin');
      expect(r.isUpgradable, isTrue);
    });

    test('standalone binary in a custom --install-dir', () {
      final r = classify('/opt/tools/bin/club');
      expect(r.method, InstallMethod.scriptStandalone);
      expect(r.destDir, '/opt/tools/bin');
    });

    test('bundle layout from install.sh', () {
      final r = classify('/Users/x/.local/share/club/bundle/bin/club');
      expect(r.method, InstallMethod.scriptBundle);
      expect(r.bundleDir, '/Users/x/.local/share/club/bundle');
      expect(r.isUpgradable, isTrue);
    });

    test('windows standalone exe', () {
      final r = classify(r'C:\Users\x\.club\bin\club.exe', windows: true);
      expect(r.method, InstallMethod.scriptStandaloneWindows);
      expect(r.destDir, r'C:\Users\x\.club\bin');
      expect(r.isUpgradable, isTrue);
    });

    test('windows bundle layout is recognised but not upgradable', () {
      final r = classify(
        r'C:\Users\x\.club\club-bundle\bin\club.exe',
        windows: true,
      );
      expect(r.method, InstallMethod.scriptBundleWindows);
      expect(r.isUpgradable, isFalse);
    });
  });

  group('homebrew', () {
    test('apple silicon cellar path', () {
      final r = classify('/opt/homebrew/Cellar/club/0.4.0/libexec/bin/club');
      expect(r.method, InstallMethod.homebrew);
      expect(r.isUpgradable, isFalse);
    });

    test('intel mac cellar path', () {
      final r = classify('/usr/local/Cellar/club/0.4.0/libexec/bin/club');
      expect(r.method, InstallMethod.homebrew);
    });

    test('linuxbrew cellar path', () {
      final r = classify(
        '/home/linuxbrew/.linuxbrew/Cellar/club/0.4.0/libexec/bin/club',
      );
      expect(r.method, InstallMethod.homebrew);
    });

    test('custom HOMEBREW_PREFIX still matches on the Cellar segment', () {
      final r = classify('/data/brew/Cellar/club/0.4.0/libexec/bin/club');
      expect(r.method, InstallMethod.homebrew);
    });
  });

  group('non-installed', () {
    test('version "dev" means dart run, whatever the executable is', () {
      final r = classify('/opt/homebrew/bin/dart', version: 'dev');
      expect(
        r.method,
        InstallMethod.devSource,
        reason: 'the dev check must beat the Homebrew path check',
      );
    });

    test('dartaotruntime is a dev build even with a real version', () {
      final r = classify('/usr/lib/dart/bin/dartaotruntime');
      expect(r.method, InstallMethod.devSource);
    });

    test('a .pub-cache script path means pub global activate', () {
      final r = classify(
        '/Users/x/.pub-cache/bin/club',
        scriptPath: '/Users/x/.pub-cache/global_packages/club_cli/bin/club.dart',
      );
      expect(r.method, InstallMethod.pubGlobal);
      expect(r.isUpgradable, isFalse);
    });

    test('an unrelated binary is unknown', () {
      final r = classify('/usr/bin/env');
      expect(r.method, InstallMethod.unknown);
      expect(r.isUpgradable, isFalse);
    });
  });

  test('a local build-cli.sh version still classifies as a script install', () {
    // Refusing to upgrade a local dev build is a decision concern, not a
    // classification one. Keeping them separate is what makes --force
    // straightforward to implement.
    final r = classify('/Users/x/.local/bin/club', version: '0.4.1-9c4f1e2.dev');
    expect(r.method, InstallMethod.scriptStandalone);
    expect(r.isUpgradable, isTrue);
  });
}
