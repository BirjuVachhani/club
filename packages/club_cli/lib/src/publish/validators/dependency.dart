/// Mirrors dart pub's
/// [`DependencyValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/dependency.dart):
/// - path dependencies are errors
/// - non-hosted non-SDK dependencies (including git) are warnings
/// - flutter must come from the SDK source
/// - unknown SDK identifiers are errors
/// - hosted deps must have sensible version constraints (lower/upper bounds,
///   no single-version pins, appropriate prerelease semantics)
library;

import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

import 'validator.dart';

/// SDK identifiers recognised by pub. The `dart` entry is implicit in
/// `environment.sdk`; the validator only sees it via `sdk: dart` dependency
/// entries, which are rare.
const _knownSdks = {'dart', 'flutter'};

class DependencyValidator extends Validator {
  DependencyValidator(super.context);

  @override
  String get name => 'DependencyValidator';

  @override
  Future<void> validate() async {
    context.pubspec.parsed.dependencies.forEach(_validateDep);
  }

  void _validateDep(String depName, Dependency dep) {
    if (depName == 'flutter') {
      _warnAboutFlutterSdk(depName, dep);
      return;
    }
    if (dep is SdkDependency) {
      _warnAboutSdkSource(depName, dep);
      return;
    }
    if (dep is PathDependency) {
      _warnAboutNonHosted(depName, 'path', isPath: true);
      return;
    }
    if (dep is GitDependency) {
      // Enhanced mode treats git deps as errors (club policy: private pub
      // repos shouldn't accept non-hosted sources). Baseline warns, matching
      // dart pub publish.
      _warnAboutNonHosted(depName, 'git', isPath: context.enhanced);
      return;
    }
    if (dep is HostedDependency) {
      _validateHosted(depName, dep);
    }
  }

  void _warnAboutFlutterSdk(String depName, Dependency dep) {
    if (dep is SdkDependency) {
      _warnAboutSdkSource(depName, dep);
      return;
    }
    error(
      'Don\'t depend on "$depName" from the ${_sourceLabel(dep)} source. '
      'Use the SDK source instead. For example:\n'
      '\n'
      'dependencies:\n'
      '  $depName:\n'
      '    sdk: flutter\n'
      '\n'
      'The Flutter SDK is downloaded and managed outside of pub.',
    );
  }

  void _warnAboutSdkSource(String depName, SdkDependency dep) {
    if (!_knownSdks.contains(dep.sdk)) {
      error('Unknown SDK "${dep.sdk}" for dependency "$depName".');
    }
  }

  void _warnAboutNonHosted(
    String depName,
    String sourceName, {
    required bool isPath,
  }) {
    final message =
        'Don\'t depend on "$depName" from the $sourceName '
        'source. Use the hosted source instead. For example:\n'
        '\n'
        'dependencies:\n'
        '  $depName: ^1.0.0\n'
        '\n'
        'Using the hosted source ensures that everyone can download your '
        'package\'s dependencies along with your package.';
    if (isPath) {
      error(message);
    } else {
      warning(message);
    }
  }

  void _validateHosted(String depName, HostedDependency dep) {
    final constraint = dep.version;

    if (constraint.isAny) {
      warning(
        'Your dependency on "$depName" should have a version constraint.\n'
        'Without a constraint, you\'re promising to support all future '
        'versions of "$depName".',
      );
      return;
    }

    if (constraint is Version) {
      warning(
        'Your dependency on "$depName" should allow more than one version.\n'
        'For example:\n'
        '\n'
        'dependencies:\n'
        '  $depName: ^$constraint\n'
        '\n'
        'Constraints that are too tight will make it difficult for people to '
        'use your package along with other packages that also depend on '
        '"$depName".',
      );
      return;
    }

    if (constraint is VersionRange) {
      _warnAboutPrerelease(depName, constraint);
      if (constraint.min == null) {
        warning(
          'Your dependency on "$depName" should have a lower bound.\n'
          'Without a lower bound, you\'re promising to support all '
          'previous versions of "$depName".',
        );
      } else if (constraint.max == null) {
        warning(
          'Your dependency on "$depName" should have an upper bound.\n'
          'Without an upper bound, you\'re promising to support all future '
          'versions of $depName.',
        );
      }
    }
  }

  void _warnAboutPrerelease(String depName, VersionRange constraint) {
    final packageVersion = context.pubspec.parsed.version;
    final min = constraint.min;
    if (min == null || !min.isPreRelease) return;
    if (packageVersion != null && packageVersion.isPreRelease) return;
    warning(
      'Packages dependent on a pre-release of another package '
      'should themselves be published as a pre-release version. '
      'If this package needs $depName version $min, '
      'consider publishing the package as a pre-release instead.\n'
      'See https://dart.dev/tools/pub/publishing#publishing-prereleases '
      'for more information on pre-releases.',
    );
  }

  String _sourceLabel(Dependency dep) {
    if (dep is PathDependency) return 'path';
    if (dep is GitDependency) return 'git';
    if (dep is HostedDependency) return 'hosted';
    if (dep is SdkDependency) return 'sdk';
    return 'unknown';
  }
}
