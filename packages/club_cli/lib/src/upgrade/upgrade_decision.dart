/// Decides what `club upgrade` should do, given versions and flags.
///
/// Kept pure and separate from the runner so the whole behaviour matrix is
/// testable without touching the network or the filesystem. The runner's
/// job is to gather inputs, call [decideUpgrade], and act on the result.
library;

import 'package:pub_semver/pub_semver.dart';

/// What the runner should do next.
enum UpgradeAction {
  /// Move to a newer version.
  upgrade,

  /// Reinstall the version already running, because of --force.
  reinstall,

  /// Move to an older version. Needs confirmation unless --yes.
  downgrade,

  /// Nothing to do.
  upToDate,

  /// Running from source. There is no installed binary to replace.
  refuseDevSource,

  /// Running a local build from scripts/build-cli.sh, or a version that
  /// does not parse. Replacing it with a release is almost never what the
  /// developer meant, so require an explicit --force or --version.
  refuseLocalBuild,
}

/// The outcome of [decideUpgrade].
class UpgradeDecision {
  const UpgradeDecision(this.action, {this.running, this.target});

  final UpgradeAction action;

  /// The parsed running version, when it parsed at all.
  final Version? running;

  /// The version that would be installed, when there is one.
  final Version? target;

  bool get proceeds =>
      action == UpgradeAction.upgrade ||
      action == UpgradeAction.reinstall ||
      action == UpgradeAction.downgrade;
}

/// Parses a version, tolerating a leading `v` and returning null on junk.
///
/// Mirrors the `_tryParseVersion` helper in club_server's update checker so
/// the two agree on what counts as a usable version string.
Version? tryParseVersion(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final trimmed = raw.startsWith('v') ? raw.substring(1) : raw;
  try {
    return Version.parse(trimmed);
  } on FormatException {
    return null;
  }
}

/// Whether [raw] is the placeholder version a `dart run` build reports.
///
/// `lib/src/version.dart` is checked in with `defaultValue: 'dev'`; both CI
/// and scripts/build-cli.sh overwrite it before building. So the literal
/// string "dev" means nobody built this, which means `dart run`.
bool isDevSourceVersion(String raw) => raw == 'dev';

/// Decides what to do.
///
/// [pinnedVersion] is the raw `--version` value, already validated as
/// parseable by the caller. When it is set, no comparison against "latest"
/// happens: the user named a version and gets it.
UpgradeDecision decideUpgrade({
  required String runningVersion,
  required String? pinnedVersion,
  required String? latestVersion,
  required bool force,
}) {
  if (isDevSourceVersion(runningVersion)) {
    // No flag rescues this one. There is no installed binary to replace,
    // and Platform.resolvedExecutable points at the Dart VM.
    return const UpgradeDecision(UpgradeAction.refuseDevSource);
  }

  final running = tryParseVersion(runningVersion);
  final explicit = pinnedVersion != null;

  // A local build-cli.sh build (0.4.1-<sha>.dev) parses fine but is a
  // developer's own binary. An unparseable version is the same class of
  // problem: we cannot reason about it, so do not silently overwrite it.
  final isLocalBuild = running == null || running.isPreRelease;
  if (isLocalBuild && !force && !explicit) {
    return UpgradeDecision(UpgradeAction.refuseLocalBuild, running: running);
  }

  final target = tryParseVersion(pinnedVersion ?? latestVersion);
  if (target == null) {
    // No resolvable target. The caller reports this as "nothing newer",
    // which is also what the asset-availability gate produces.
    return UpgradeDecision(UpgradeAction.upToDate, running: running);
  }

  if (running == null) {
    // Unparseable running version, but the user was explicit. Install what
    // they asked for; we have nothing to compare against.
    return UpgradeDecision(UpgradeAction.upgrade, target: target);
  }

  if (target == running) {
    return UpgradeDecision(
      force ? UpgradeAction.reinstall : UpgradeAction.upToDate,
      running: running,
      target: target,
    );
  }

  if (target < running) {
    return UpgradeDecision(
      UpgradeAction.downgrade,
      running: running,
      target: target,
    );
  }

  return UpgradeDecision(
    UpgradeAction.upgrade,
    running: running,
    target: target,
  );
}
