/// Mirrors dart pub's
/// [`SdkConstraintValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/sdk_constraint.dart):
/// requires an SDK constraint with an upper bound, warns about prerelease
/// minimums, and hints when the declared constraint differs from pub's
/// effective interpretation (e.g. the `<3.0.0` → `<4.0.0` null-safety
/// rewrite on Dart 3+).
library;

import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import 'validator.dart';

/// First Dart language version that enabled null safety by default.
final _firstNullSafetyLanguageVersion = Version(2, 12, 0);

class SdkConstraintValidator extends Validator {
  SdkConstraintValidator(super.context);

  @override
  String get name => 'SdkConstraintValidator';

  @override
  Future<void> validate() async {
    final env = context.pubspec.parsed.environment;
    final originalConstraint = env['sdk'];
    if (originalConstraint == null ||
        originalConstraint == VersionConstraint.any) {
      error(
        'Your pubspec.yaml must have a Dart SDK constraint with an upper '
        'bound, for example `sdk: ^3.0.0`.\n'
        'See https://dart.dev/tools/pub/pubspec#sdk-constraints',
      );
      return;
    }
    if (originalConstraint is! VersionRange) return;

    var emittedIssue = false;

    if (originalConstraint.max == null) {
      error(
        'Published packages should have an upper bound constraint on the '
        'Dart SDK (typically this should restrict to less than the next '
        'major version to guard against breaking changes).\n'
        'See https://dart.dev/tools/pub/pubspec#sdk-constraints for '
        'instructions on setting an sdk version constraint.',
      );
      emittedIssue = true;
    }

    final min = originalConstraint.min;
    final packageVersion = context.pubspec.parsed.version;
    if (min != null &&
        min.isPreRelease &&
        packageVersion != null &&
        !packageVersion.isPreRelease) {
      warning(
        'Packages with an SDK constraint on a pre-release of the Dart SDK '
        'should themselves be published as a pre-release version. '
        'If this package needs Dart version $min, consider publishing the '
        'package as a pre-release instead.\n'
        'See https://dart.dev/tools/pub/publishing#publishing-prereleases '
        'for more information on pre-releases.',
      );
      emittedIssue = true;
    }

    if (!emittedIssue) {
      final effective = _effectiveConstraint(originalConstraint);
      if (effective != originalConstraint) {
        hint(
          'The declared SDK constraint is \'$originalConstraint\', '
          'this is interpreted as \'$effective\'.\n\n'
          'Consider updating the SDK constraint to:\n\n'
          'environment:\n'
          '  sdk: \'$effective\'\n',
        );
      }
    }
  }

  /// Pub's `SdkConstraint.interpretDartSdkConstraint` null-safety rewrite:
  /// on Dart 3+, a null-safety-enabled constraint with `<3.0.0` upper bound
  /// is interpreted as `<4.0.0` so the package still resolves on Dart 3.
  ///
  /// The other transformation pub applies (default upper bound intersection
  /// for language versions < 1.8) is legacy and doesn't apply to any
  /// modern package, so we skip it.
  VersionConstraint _effectiveConstraint(VersionRange original) {
    if (_runningDartMajor < 3) return original;
    final min = original.min;
    if (min == null || min < _firstNullSafetyLanguageVersion) return original;
    // `<3.0.0` is parsed by pub_semver as max = 3.0.0-0 with includeMax
    // false.
    final threeZeroZeroPre = Version(3, 0, 0).firstPreRelease;
    if (original.max != threeZeroZeroPre || original.includeMax) {
      return original;
    }
    return VersionRange(
      min: original.min,
      includeMin: original.includeMin,
      max: Version(4, 0, 0),
    );
  }

  static final int _runningDartMajor = () {
    // Platform.version looks like "3.11.0 (stable) (Wed ... ) ...".
    final m = RegExp(r'^(\d+)\.').firstMatch(Platform.version);
    return m == null ? 0 : int.parse(m.group(1)!);
  }();
}
