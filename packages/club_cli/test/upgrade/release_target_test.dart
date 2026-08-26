import 'package:club_cli/src/upgrade/release_target.dart';
import 'package:test/test.dart';

void main() {
  // These names are the contract with .github/workflows/build-cli.yml.
  // The "Pack archive" step builds `club-cli-${VERSION}-${TARGET}` and the
  // `tap` job reads the same names back out of SHA256SUMS.txt. If CI's
  // naming changes, this test should fail before users get a 404.
  group('asset names match build-cli.yml', () {
    test('every published target', () {
      expect(
        archiveName('0.4.2', 'linux-x64'),
        'club-cli-0.4.2-linux-x64.tar.gz',
      );
      expect(
        archiveName('0.4.2', 'linux-arm64'),
        'club-cli-0.4.2-linux-arm64.tar.gz',
      );
      expect(
        archiveName('0.4.2', 'macos-x64'),
        'club-cli-0.4.2-macos-x64.tar.gz',
      );
      expect(
        archiveName('0.4.2', 'macos-arm64'),
        'club-cli-0.4.2-macos-arm64.tar.gz',
      );
      expect(
        archiveName('0.4.2', 'windows-x64'),
        'club-cli-0.4.2-windows-x64.zip',
      );
      expect(
        archiveName('0.4.2', 'windows-arm64'),
        'club-cli-0.4.2-windows-arm64.zip',
      );
    });

    test('a pre-release version keeps its suffix in the asset name', () {
      expect(
        archiveName('0.5.0-rc.1', 'macos-arm64'),
        'club-cli-0.5.0-rc.1-macos-arm64.tar.gz',
      );
    });

    test('the target set is exactly the CI matrix', () {
      expect(releaseTargets, {
        'linux-x64',
        'linux-arm64',
        'macos-x64',
        'macos-arm64',
        'windows-x64',
        'windows-arm64',
      });
    });
  });

  group('resolveTarget', () {
    String? resolve(String version, String os) =>
        resolveTarget(dartVersion: version, operatingSystem: os);

    test('apple silicon', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "macos_arm64"', 'macos'),
        'macos-arm64',
      );
    });

    test('intel mac', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "macos_x64"', 'macos'),
        'macos-x64',
      );
    });

    test('linux x64', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "linux_x64"', 'linux'),
        'linux-x64',
      );
    });

    test('linux arm64', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "linux_arm64"', 'linux'),
        'linux-arm64',
      );
    });

    test('windows x64', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "windows_x64"', 'windows'),
        'windows-x64',
      );
    });

    test('windows arm64', () {
      expect(
        resolve('3.12.2 (stable) (Tue) on "windows_arm64"', 'windows'),
        'windows-arm64',
      );
    });

    test('an unsupported OS resolves to null', () {
      expect(resolve('3.12.2 (stable) on "android_arm64"', 'android'), isNull);
    });

    test('an unsupported CPU resolves to null', () {
      expect(resolve('3.12.2 (stable) on "linux_riscv64"', 'linux'), isNull);
    });

    test('falls back to uname when the version suffix is missing', () {
      expect(
        resolveTarget(
          dartVersion: '3.12.2 (stable)',
          operatingSystem: 'linux',
          unameArch: 'aarch64',
        ),
        'linux-arm64',
      );
      expect(
        resolveTarget(
          dartVersion: '3.12.2 (stable)',
          operatingSystem: 'linux',
          unameArch: 'x86_64',
        ),
        'linux-x64',
      );
    });

    test('the version suffix wins over the uname fallback', () {
      expect(
        resolveTarget(
          dartVersion: '3.12.2 (stable) on "macos_arm64"',
          operatingSystem: 'macos',
          unameArch: 'x86_64',
        ),
        'macos-arm64',
      );
    });
  });

  test('detectTarget resolves this machine', () {
    // Whatever runs the suite must be one of the published targets, or
    // the release matrix has a hole.
    expect(releaseTargets, contains(detectTarget()));
  });
}
