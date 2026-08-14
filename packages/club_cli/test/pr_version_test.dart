import 'package:club_cli/src/publish/pr_version.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  group('prSuffix', () {
    test('formats the PR number', () {
      expect(prSuffix(2), 'pr2');
      expect(prSuffix(1234), 'pr1234');
    });
  });

  group('applyPrereleaseSuffix', () {
    test('plain release becomes a prerelease', () {
      expect(applyPrereleaseSuffix('1.2.0', 'pr2'), '1.2.0-pr2');
    });

    test('appends to an existing prerelease', () {
      expect(applyPrereleaseSuffix('1.2.0-dev.3', 'pr2'), '1.2.0-dev.3.pr2');
    });

    test('build metadata stays last', () {
      expect(applyPrereleaseSuffix('1.2.0+5', 'pr2'), '1.2.0-pr2+5');
    });

    test('prerelease and build metadata together', () {
      expect(
        applyPrereleaseSuffix('1.2.0-beta.1+abc', 'pr7'),
        '1.2.0-beta.1.pr7+abc',
      );
    });

    test('applying the same suffix twice is a no-op', () {
      final once = applyPrereleaseSuffix('1.2.0', 'pr2');
      expect(applyPrereleaseSuffix(once, 'pr2'), once);
    });

    test('a different PR suffix still appends', () {
      expect(applyPrereleaseSuffix('1.2.0-pr2', 'pr3'), '1.2.0-pr2.pr3');
    });

    test('0.x versions are handled like any other', () {
      expect(applyPrereleaseSuffix('0.1.0', 'pr9'), '0.1.0-pr9');
    });

    test('invalid semver throws', () {
      expect(
        () => applyPrereleaseSuffix('not-a-version', 'pr2'),
        throwsFormatException,
      );
    });
  });

  group('ordering', () {
    test('a PR build sorts below the release it is derived from', () {
      // This is the property that makes the suffix safe: `^1.2.0` will not
      // pick up `1.2.0-pr2`, so a PR publish cannot leak into a consumer
      // that asked for the stable version.
      expect(
        Version.parse(applyPrereleaseSuffix('1.2.0', 'pr2')) <
            Version.parse('1.2.0'),
        isTrue,
      );
    });
  });
}
