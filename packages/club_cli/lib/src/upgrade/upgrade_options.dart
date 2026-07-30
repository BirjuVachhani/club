/// Parsed options for `club upgrade`.
library;

export '../util/exit_codes.dart' show ExitCodes;

class UpgradeOptions {
  UpgradeOptions({
    this.check = false,
    this.version,
    this.pre = false,
    this.force = false,
    this.dryRun = false,
    this.yes = false,
    this.installDir,
    this.json = false,
  });

  /// `--check` — report whether a newer release exists, then exit.
  final bool check;

  /// `--version` — install this exact version instead of the latest.
  final String? version;

  /// `--pre` — consider pre-release tags when resolving the latest version.
  final bool pre;

  /// `--force` — reinstall when already current, and proceed on a local
  /// dev build.
  final bool force;

  /// `--dry-run` — print what would happen, then exit.
  final bool dryRun;

  /// `--yes` — skip the downgrade confirmation.
  final bool yes;

  /// `--install-dir` — override the auto-detected install directory.
  final String? installDir;

  /// `--json` — machine-readable output.
  final bool json;
}
