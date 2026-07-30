import 'package:club_cli/src/upgrade/upgrade_decision.dart';
import 'package:test/test.dart';

void main() {
  UpgradeDecision decide({
    String running = '0.4.1',
    String? pinned,
    String? latest = '0.4.2',
    bool force = false,
  }) =>
      decideUpgrade(
        runningVersion: running,
        pinnedVersion: pinned,
        latestVersion: latest,
        force: force,
      );

  group('normal releases', () {
    test('a newer latest is an upgrade', () {
      final d = decide();
      expect(d.action, UpgradeAction.upgrade);
      expect(d.target.toString(), '0.4.2');
      expect(d.proceeds, isTrue);
    });

    test('the same version is up to date', () {
      expect(decide(latest: '0.4.1').action, UpgradeAction.upToDate);
    });

    test('--force on the same version reinstalls', () {
      expect(
        decide(latest: '0.4.1', force: true).action,
        UpgradeAction.reinstall,
      );
    });

    test('an older latest is never offered as an upgrade', () {
      // Should not happen, but a bad API response must not roll users back.
      expect(decide(latest: '0.3.0').action, UpgradeAction.downgrade);
    });

    test('a leading v on the tag is tolerated', () {
      expect(decide(latest: 'v0.4.2').action, UpgradeAction.upgrade);
    });

    test('no resolvable latest is treated as up to date', () {
      // This is the asset-availability gate's path: a release exists but
      // its binaries have not landed, so we behave as if there is none.
      expect(decide(latest: null).action, UpgradeAction.upToDate);
    });
  });

  group('--version pinning', () {
    test('an older pin is a downgrade', () {
      final d = decide(pinned: '0.3.0');
      expect(d.action, UpgradeAction.downgrade);
      expect(d.target.toString(), '0.3.0');
    });

    test('a newer pin is an upgrade', () {
      expect(decide(pinned: '0.9.0').action, UpgradeAction.upgrade);
    });

    test('pinning the running version is up to date without --force', () {
      expect(decide(pinned: '0.4.1').action, UpgradeAction.upToDate);
    });

    test('a pin overrides latest entirely', () {
      final d = decide(pinned: '0.3.0', latest: '9.9.9');
      expect(d.action, UpgradeAction.downgrade);
      expect(d.target.toString(), '0.3.0');
    });
  });

  group('dart run (version "dev")', () {
    test('refuses', () {
      expect(decide(running: 'dev').action, UpgradeAction.refuseDevSource);
    });

    test('refuses even with --force', () {
      expect(
        decide(running: 'dev', force: true).action,
        UpgradeAction.refuseDevSource,
      );
    });

    test('refuses even with an explicit --version', () {
      expect(
        decide(running: 'dev', pinned: '0.4.2').action,
        UpgradeAction.refuseDevSource,
      );
    });
  });

  group('local build-cli.sh build (0.4.1-<sha>.dev)', () {
    const local = '0.4.1-9c4f1e2.dev';

    test('refuses a bare upgrade', () {
      expect(decide(running: local).action, UpgradeAction.refuseLocalBuild);
    });

    test('--force proceeds', () {
      expect(decide(running: local, force: true).action, UpgradeAction.upgrade);
    });

    test('an explicit --version proceeds', () {
      expect(
        decide(running: local, pinned: '0.4.2').action,
        UpgradeAction.upgrade,
      );
    });

    test('a published pre-release is treated the same way', () {
      // 0.5.0-rc.1 from a real release is still a pre-release, and the
      // stable channel moving "backwards" onto 0.4.9 would surprise.
      expect(
        decide(running: '0.5.0-rc.1').action,
        UpgradeAction.refuseLocalBuild,
      );
    });
  });

  group('unparseable running version', () {
    test('refuses a bare upgrade', () {
      expect(decide(running: 'garbage').action, UpgradeAction.refuseLocalBuild);
    });

    test('an explicit --version proceeds, since there is nothing to compare', () {
      final d = decide(running: 'garbage', pinned: '0.4.2');
      expect(d.action, UpgradeAction.upgrade);
      expect(d.running, isNull);
    });
  });

  group('tryParseVersion', () {
    test('strips a leading v', () {
      expect(tryParseVersion('v1.2.3').toString(), '1.2.3');
    });

    test('accepts a bare semver', () {
      expect(tryParseVersion('1.2.3').toString(), '1.2.3');
    });

    test('returns null on junk, empty, and null', () {
      expect(tryParseVersion('not-a-version'), isNull);
      expect(tryParseVersion(''), isNull);
      expect(tryParseVersion(null), isNull);
    });
  });

  test('isDevSourceVersion matches only the literal placeholder', () {
    expect(isDevSourceVersion('dev'), isTrue);
    expect(isDevSourceVersion('0.4.1-9c4f1e2.dev'), isFalse);
    expect(isDevSourceVersion('0.4.1'), isFalse);
  });
}
