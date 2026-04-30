/// Mirrors dart pub's
/// [`RelativeVersionNumberingValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/relative_version_numbering.dart):
/// hints when the new version isn't a sensible increment from the previous
/// release, when it's earlier than the currently-published latest, or when
/// null-safety opt-in changes across versions.
library;

import 'package:pub_semver/pub_semver.dart';

import 'validator.dart';

/// The Dart language version at which null-safety became the default.
final _nullSafetyLanguageVersion = Version(2, 12, 0);

const _semverUrl = 'https://dart.dev/tools/pub/versioning#semantic-versions';
const _nullSafetyGuideUrl = 'https://dart.dev/null-safety/migration-guide';

class RelativeVersionValidator extends Validator {
  RelativeVersionValidator(super.context);

  @override
  String get name => 'RelativeVersionValidator';

  @override
  Future<void> validate() async {
    if (context.publishedVersions.isEmpty) return;

    final current = Version.parse(context.pubspec.version);
    final published = context.publishedVersions.map(Version.parse).toList()
      ..sort();
    final latest = published.last;

    if (latest > current) {
      hint(
        'The latest published version is $latest.\n'
        'Your version $current is earlier than that.',
      );
    }

    final previous = published.where((v) => v < current).fold<Version?>(null, (
      a,
      b,
    ) {
      if (a == null) return b;
      return b > a ? b : a;
    });
    if (previous == null) return;

    final noPrerelease = Version(current.major, current.minor, current.patch);
    final isSensibleIncrement =
        noPrerelease == previous.nextMajor ||
        noPrerelease == previous.nextMinor ||
        noPrerelease == previous.nextPatch ||
        _withoutBuild(current) == previous;
    if (!isSensibleIncrement) {
      final suggestion = previous.major == 0
          ? '* ${previous.nextMajor} for a first major release.\n'
                '* ${previous.nextBreaking} for a breaking release.\n'
                '* ${previous.nextPatch} for a minor release.'
          : '* ${previous.nextBreaking} for a breaking release.\n'
                '* ${previous.nextMinor} for a minor release.\n'
                '* ${previous.nextPatch} for a patch release.';

      hint(
        'The previous version is $previous.\n\n'
        'It seems you are not publishing an incremental update.\n\n'
        'Consider one of:\n$suggestion',
      );
    }

    await _checkNullSafety(previous);
  }

  Future<void> _checkNullSafety(Version previous) async {
    final fetch = context.fetchPublishedPubspec;
    if (fetch == null) return;

    final prevPubspec = await fetch(previous.toString());
    if (prevPubspec == null) return;

    final currentOptedIn = _optsIntoNullSafety(context.pubspec.rawMap);
    final previousOptedIn = _optsIntoNullSafety(prevPubspec);

    if (currentOptedIn && !previousOptedIn) {
      hint(
        "You're about to publish a package that opts into null safety.\n"
        "The previous version ($previous) isn't opted in.\n"
        'See $_nullSafetyGuideUrl for best practices.',
      );
    } else if (!currentOptedIn && previousOptedIn) {
      hint(
        "You're about to publish a package that doesn't opt into null "
        'safety,\nbut the previous version ($previous) was opted in.\n'
        'This change is likely to be backwards incompatible.\n'
        'See $_semverUrl for information about versioning.',
      );
    }
  }

  /// A package opts into null safety if its minimum SDK constraint is
  /// >= 2.12.0 (the language version where null safety became default).
  bool _optsIntoNullSafety(Map<dynamic, dynamic> pubspec) {
    final env = pubspec['environment'];
    if (env is! Map) return false;
    final sdkRaw = env['sdk'];
    if (sdkRaw is! String) return false;
    final VersionConstraint constraint;
    try {
      constraint = VersionConstraint.parse(sdkRaw);
    } on FormatException {
      return false;
    }
    if (constraint is! VersionRange) return false;
    final min = constraint.min;
    if (min == null) return false;
    return min.compareTo(_nullSafetyLanguageVersion) >= 0;
  }

  Version _withoutBuild(Version v) => Version(
    v.major,
    v.minor,
    v.patch,
    pre: v.preRelease.isEmpty ? null : v.preRelease.join('.'),
  );
}
