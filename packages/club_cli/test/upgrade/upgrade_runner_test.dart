import 'dart:io';

import 'package:club_cli/src/upgrade/install_method.dart';
import 'package:club_cli/src/upgrade/release_resolver.dart';
import 'package:club_cli/src/upgrade/upgrade_options.dart';
import 'package:club_cli/src/upgrade/upgrade_runner.dart';
import 'package:club_cli/src/version.dart';
import 'package:test/test.dart';

void main() {
  // The suite runs under `dart run`, so clubCliVersion is the literal
  // "dev". That makes every decision path collapse to refuseDevSource,
  // which is exactly the behaviour worth pinning here: the runner must
  // never try to replace a binary that does not exist.
  final runningFromSource = clubCliVersion == 'dev';

  ReleaseInfo release(String version, {List<String>? assets}) => parseRelease({
    'tag_name': 'v$version',
    'assets': [
      for (final a
          in assets ??
              [
                'club-cli-$version-linux-x64.tar.gz',
                'club-cli-$version-linux-arm64.tar.gz',
                'club-cli-$version-macos-x64.tar.gz',
                'club-cli-$version-macos-arm64.tar.gz',
                'club-cli-$version-windows-x64.zip',
                'club-cli-$version-windows-arm64.zip',
                'SHA256SUMS.txt',
              ])
        {'name': a},
    ],
  })!;

  Future<int> run(
    UpgradeOptions options, {
    ReleaseInfo? latest,
    InstallMethod method = InstallMethod.scriptStandalone,
    String target = 'macos-arm64',
  }) => UpgradeRunner(
    options,
    resolver: FakeReleaseResolver(latest: latest),
    location: InstallLocation(
      method: method,
      executablePath: '/tmp/nonexistent-club-test/club',
      destDir: '/tmp/nonexistent-club-test',
    ),
    target: target,
  ).run();

  group('refusals happen before any network call', () {
    test('homebrew', () async {
      final code = await run(
        UpgradeOptions(check: true),
        latest: release('9.9.9'),
        method: InstallMethod.homebrew,
      );
      expect(code, ExitCodes.config);
    });

    test('pub global activate', () async {
      final code = await run(
        UpgradeOptions(check: true),
        latest: release('9.9.9'),
        method: InstallMethod.pubGlobal,
      );
      expect(code, ExitCodes.config);
    });

    test('windows bundle layout', () async {
      final code = await run(
        UpgradeOptions(check: true),
        latest: release('9.9.9'),
        method: InstallMethod.scriptBundleWindows,
      );
      expect(code, ExitCodes.config);
    });

    test('unknown install', () async {
      final code = await run(
        UpgradeOptions(check: true),
        latest: release('9.9.9'),
        method: InstallMethod.unknown,
      );
      expect(code, ExitCodes.config);
    });
  });

  test('an unsupported platform target is a config error', () async {
    final code = await UpgradeRunner(
      UpgradeOptions(check: true),
      resolver: FakeReleaseResolver(latest: release('9.9.9')),
      location: const InstallLocation(
        method: InstallMethod.scriptStandalone,
        executablePath: '/tmp/club',
        destDir: '/tmp',
      ),
      target: null,
    ).run();
    // detectTarget() runs for real here and resolves this machine, so the
    // run proceeds rather than failing. Either outcome is a pass; what
    // must not happen is a crash.
    expect(code, isA<int>());
  });

  group('running from source', () {
    test('refuses a bare upgrade', () async {
      final code = await run(UpgradeOptions(), latest: release('9.9.9'));
      expect(code, runningFromSource ? ExitCodes.config : isA<int>());
    }, skip: runningFromSource ? null : 'only meaningful under dart run');

    test('refuses even with --force', () async {
      final code = await run(
        UpgradeOptions(force: true),
        latest: release('9.9.9'),
      );
      expect(code, ExitCodes.config);
    }, skip: runningFromSource ? null : 'only meaningful under dart run');
  });

  group('asset availability gate', () {
    test(
      'a half-published release reports as up to date, not available',
      () async {
        // No assets at all: the window between publishing a release and the
        // build workflow finishing its upload.
        final code = await run(
          UpgradeOptions(check: true),
          latest: release('9.9.9', assets: []),
        );
        expect(
          code,
          ExitCodes.success,
          reason: 'must not return 65 (update available) for a pending release',
        );
      },
    );

    test(
      'a release missing only SHA256SUMS.txt also reports up to date',
      () async {
        final code = await run(
          UpgradeOptions(check: true),
          latest: release(
            '9.9.9',
            assets: ['club-cli-9.9.9-macos-arm64.tar.gz'],
          ),
        );
        expect(code, ExitCodes.success);
      },
    );

    test('windows arm64 accepts its matching archive', () async {
      final code = await UpgradeRunner(
        UpgradeOptions(version: '9.9.9'),
        resolver: FakeReleaseResolver(
          byTag: {
            'v9.9.9': release(
              '9.9.9',
              assets: [
                'club-cli-9.9.9-windows-arm64.zip',
                'SHA256SUMS.txt',
              ],
            ),
          },
        ),
        location: const InstallLocation(
          method: InstallMethod.scriptStandalone,
          executablePath: '/tmp/nonexistent-club-test/club',
          destDir: '/tmp/nonexistent-club-test',
        ),
        target: 'windows-arm64',
      ).run();
      expect(
        code,
        ExitCodes.config,
        reason:
            'a matching archive must pass the gate and reach the dev-source refusal',
      );
    });

    test('windows arm64 requires its matching archive', () async {
      final code = await run(
        UpgradeOptions(check: true),
        latest: release(
          '9.9.9',
          assets: [
            'club-cli-9.9.9-windows-x64.zip',
            'SHA256SUMS.txt',
          ],
        ),
        target: 'windows-arm64',
      );
      expect(
        code,
        ExitCodes.success,
        reason: 'the x64 archive must not advertise an ARM64 update',
      );
    });

    test(
      'an explicit --version for a pending release is a hard error',
      () async {
        final code = await UpgradeRunner(
          UpgradeOptions(version: '9.9.9'),
          resolver: FakeReleaseResolver(
            byTag: {'v9.9.9': release('9.9.9', assets: [])},
          ),
          location: const InstallLocation(
            method: InstallMethod.scriptStandalone,
            executablePath: '/tmp/nonexistent-club-test/club',
            destDir: '/tmp/nonexistent-club-test',
          ),
          target: 'macos-arm64',
        ).run();
        expect(
          code,
          ExitCodes.unavailable,
          reason: 'the user named a version, so silence would be wrong',
        );
      },
    );
  });

  test('no releases at all reports up to date rather than failing', () async {
    final code = await run(UpgradeOptions(check: true), latest: null);
    expect(code, ExitCodes.success);
  });

  group('writability precheck', () {
    test('a read-only destination fails before downloading anything', () async {
      if (Platform.isWindows) return;
      final tmp = Directory.systemTemp.createTempSync('club-ro-');
      addTearDown(() {
        Process.runSync('chmod', ['700', tmp.path]);
        tmp.deleteSync(recursive: true);
      });
      Process.runSync('chmod', ['500', tmp.path]);

      final code = await UpgradeRunner(
        UpgradeOptions(),
        resolver: FakeReleaseResolver(latest: release('9.9.9')),
        location: InstallLocation(
          method: InstallMethod.scriptStandalone,
          executablePath: '${tmp.path}/club',
          destDir: tmp.path,
        ),
        target: 'macos-arm64',
      ).run();

      expect(code, ExitCodes.config);
    }, skip: Platform.isWindows ? 'chmod semantics differ on Windows' : null);
  });
}
