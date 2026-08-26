/// The release-artifact contract: platform targets and asset names.
///
/// Every string here has to match what `.github/workflows/build-cli.yml`
/// produces. The relevant steps are "Stage bundle for packaging" and
/// "Pack archive", which build `club-cli-<version>-<target>` as both the
/// archive root and the archive name.
///
/// This is the one place `club upgrade` duplicates knowledge that also
/// lives in the installer scripts, so `release_target_test.dart` pins every
/// published name. If CI's naming ever changes, that test fails rather than
/// users getting a 404.
library;

import 'dart:io';

/// Every target `build-cli.yml` publishes.
const releaseTargets = <String>{
  'linux-x64',
  'linux-arm64',
  'macos-x64',
  'macos-arm64',
  'windows-x64',
  'windows-arm64',
};

/// The release asset name for [version] on [target].
///
/// Windows ships a `.zip` because `Compress-Archive` is what the Windows
/// runner has; every other target ships a `.tar.gz`.
String archiveName(String version, String target) {
  final ext = target.startsWith('windows') ? 'zip' : 'tar.gz';
  return 'club-cli-$version-$target.$ext';
}

/// The single checksums file published alongside every release asset.
const sha256SumsName = 'SHA256SUMS.txt';

/// Resolves the release target for the running machine.
///
/// [dartVersion] is `Platform.version`, which ends with `on "<os>_<arch>"`
/// (e.g. `on "macos_arm64"`). That suffix is the cheapest arch signal
/// available in pure Dart. [unameArch] is an optional fallback for when
/// the suffix is missing or unrecognised.
///
/// Returns null when the platform has no published build, which the
/// caller should turn into a clear "no build for your platform" message
/// rather than a 404 from GitHub.
String? resolveTarget({
  required String dartVersion,
  required String operatingSystem,
  String? unameArch,
}) {
  final os = switch (operatingSystem) {
    'linux' => 'linux',
    'macos' => 'macos',
    'windows' => 'windows',
    _ => null,
  };
  if (os == null) return null;

  final arch = _normaliseArch(_archFromDartVersion(dartVersion) ?? unameArch);
  if (arch == null) return null;

  final target = '$os-$arch';
  return releaseTargets.contains(target) ? target : null;
}

/// Pulls `arm64` out of a `Platform.version` ending in `on "macos_arm64"`.
String? _archFromDartVersion(String dartVersion) {
  final match = RegExp(
    r'on "([a-z0-9]+)_([a-z0-9_]+)"',
  ).firstMatch(dartVersion);
  return match?.group(2);
}

/// Normalises the many spellings of the same CPU to the release target's.
///
/// Matches the normalisation in club_server's `sdk_manager.dart` so the
/// two never disagree about what machine they are on.
String? _normaliseArch(String? raw) => switch (raw) {
  'arm64' || 'aarch64' => 'arm64',
  'x64' || 'x86_64' || 'amd64' => 'x64',
  _ => null,
};

/// Resolves the release target for this process.
String? detectTarget() {
  final direct = resolveTarget(
    dartVersion: Platform.version,
    operatingSystem: Platform.operatingSystem,
  );
  if (direct != null) return direct;

  // The version-string suffix is stable in practice, but it is a display
  // string rather than an API. Fall back to uname before giving up.
  if (Platform.isWindows) return null;
  try {
    final result = Process.runSync('uname', ['-m']);
    if (result.exitCode != 0) return null;
    return resolveTarget(
      dartVersion: '',
      operatingSystem: Platform.operatingSystem,
      unameArch: (result.stdout as String).trim(),
    );
  } on ProcessException {
    return null;
  }
}
