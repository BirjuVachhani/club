/// Base class + shared types for publish-time validators.
///
/// Mirrors dart pub's
/// [`Validator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator.dart)
/// abstraction. Each individual validator subclasses [Validator] and adds
/// errors/warnings/hints to its own collected lists; the runner aggregates
/// them across all validators.
library;

import '../pubspec_reader.dart';
import '../tarball_builder.dart';

/// Severity of a single validator finding.
enum Severity {
  /// Blocks publish.
  error,

  /// Asks confirmation (or fails with `--ignore-warnings` not set in CI).
  warning,

  /// Informational only — never blocks.
  hint,
}

/// A single validator finding.
class ValidationFinding {
  ValidationFinding(this.severity, this.message);
  final Severity severity;
  final String message;
}

/// Inputs available to every validator.
class ValidationContext {
  ValidationContext({
    required this.pubspec,
    required this.tarball,
    required this.serverUrl,
    this.publishedVersions = const [],
    this.enhanced = false,
    this.fetchPublishedPubspec,
    this.workspaceRootDir,
    this.resolvedPackageDir,
    this.resolutionDeferred = false,
  });

  final PackagePubspec pubspec;
  final BuiltTarball tarball;

  /// URL of the target server (for relative-version checks against the
  /// existing release history).
  final String serverUrl;

  /// Sorted list of versions already published for this package on the
  /// target server. Empty if this is a brand-new package.
  final List<String> publishedVersions;

  /// `--enhanced` / `-e` mode: run club-specific extras on top of the
  /// dart-pub baseline (e.g. stricter lints, extra leak patterns, stricter
  /// size enforcement). Off by default so default behaviour matches dart
  /// pub publish.
  final bool enhanced;

  /// Lazily fetches the published pubspec for `version` of this package,
  /// or returns `null` if unavailable. Used by validators that need to
  /// inspect prior releases (e.g. null-safety migration check).
  final Future<Map<String, dynamic>?> Function(String version)?
  fetchPublishedPubspec;

  /// Absolute path of the workspace root when the package is part of a pub
  /// workspace, otherwise `null`. Used for workspace-wide checks like
  /// dependency overrides.
  final String? workspaceRootDir;

  /// Absolute path of the scratch directory the archive was unpacked and
  /// resolved into, or `null` when resolution was skipped (`--from-archive`,
  /// `--skip-validation`).
  ///
  /// Validators that read package sources should prefer this over
  /// [PackagePubspec.directory]: it contains exactly the files that will
  /// ship, and it is the only tree guaranteed to have a
  /// `.dart_tool/package_config.json`. Use [sourceDir].
  final String? resolvedPackageDir;

  /// True when this package belongs to a dependency cycle, so its standalone
  /// resolution was deferred until every member of the group is published.
  ///
  /// Checks that need a *resolved* package cannot produce a trustworthy
  /// answer in that window: the package's siblings are not on the server yet,
  /// so there is no `.dart_tool/package_config.json` to resolve imports
  /// against and no rewritten tree to analyse. Such validators skip
  /// themselves here and run again in the post-publish verification pass,
  /// where the cycle is closed. See `publish/cycle_verification.dart`.
  final bool resolutionDeferred;

  /// Directory to read package sources from — the resolved scratch copy when
  /// available, the original package directory otherwise.
  String get sourceDir => resolvedPackageDir ?? pubspec.directory;
}

/// Base class for all publish-time validators.
abstract class Validator {
  Validator(this.context);

  final ValidationContext context;

  /// Stable name (matches dart pub's class name) for diagnostics.
  String get name;

  /// All findings produced by this validator after [validate] runs.
  final List<ValidationFinding> findings = [];

  /// Run the validation. Should populate [findings].
  Future<void> validate();

  // ── Helpers ──────────────────────────────────────────────────────────────

  void error(String message) =>
      findings.add(ValidationFinding(Severity.error, message));
  void warning(String message) =>
      findings.add(ValidationFinding(Severity.warning, message));
  void hint(String message) =>
      findings.add(ValidationFinding(Severity.hint, message));
}
