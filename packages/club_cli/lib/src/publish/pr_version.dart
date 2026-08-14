/// Version derivation for pull request publishes.
///
/// Publishing a PR must not overwrite a real release, so the package's own
/// version is turned into a prerelease of itself: `1.2.0` published from PR
/// #2 becomes `1.2.0-pr2`.
///
/// The suffix deliberately carries no commit hash. Every publish of the same
/// PR produces the same version, so updating a PR build is a re-publish of
/// `1.2.0-pr2` (with `--force`) rather than an ever-growing list of versions
/// nobody will clean up.
library;

import 'package:pub_semver/pub_semver.dart' as semver;

/// Prerelease identifier used for pull request [number], e.g. `pr2`.
String prSuffix(int number) => 'pr$number';

/// Returns [version] as a prerelease identified by [suffix].
///
/// * `1.2.0` + `pr2` -> `1.2.0-pr2`
/// * `1.2.0-dev.3` + `pr2` -> `1.2.0-dev.3.pr2` (appended, so the ordering
///   the author already established is preserved)
/// * `1.2.0+5` + `pr2` -> `1.2.0-pr2+5` (build metadata always sorts last)
///
/// Applying the same suffix twice is a no-op, so a pubspec that already
/// pins a PR version does not accumulate `-pr2.pr2`.
///
/// Throws [FormatException] when [version] is not valid semver.
String applyPrereleaseSuffix(String version, String suffix) {
  final parsed = semver.Version.parse(version);

  final pre = [...parsed.preRelease.map((p) => p.toString())];
  if (pre.contains(suffix)) return version;
  pre.add(suffix);

  return semver.Version(
    parsed.major,
    parsed.minor,
    parsed.patch,
    pre: pre.join('.'),
    build: parsed.build.isEmpty
        ? null
        : parsed.build.map((b) => b.toString()).join('.'),
  ).toString();
}
