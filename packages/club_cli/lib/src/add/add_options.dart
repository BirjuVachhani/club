/// Parsed options + positional arguments for `club add`.
library;

import 'package:pub_semver/pub_semver.dart' as semver;

export '../util/exit_codes.dart' show ExitCodes;

/// Which section of pubspec.yaml the entry goes into.
enum DepSection {
  dependencies('dependencies'),
  devDependencies('dev_dependencies'),
  dependencyOverrides('dependency_overrides')
  ;

  const DepSection(this.key);
  final String key;
}

/// A single parsed `[<section>:]<package>[:<descriptor>]` token.
///
/// Only hosted dependencies are supported in v1. `explicitHostedUrl` is set
/// when the user gave a descriptor like `foo:{hosted: https://my-pub.dev}`;
/// in that case we skip the multi-server search and target the pinned URL.
class AddRequest {
  AddRequest({
    required this.name,
    required this.section,
    this.explicitConstraint,
    this.explicitHostedUrl,
    this.rawDescriptor,
  });

  final String name;
  final DepSection section;

  /// Constraint explicitly provided by the user (e.g. `^1.2.3`, `>=1.0.0 <2`,
  /// or a bare `1.0.0`). When null, the runner derives `^<latest-stable>`
  /// from the target server.
  final semver.VersionConstraint? explicitConstraint;

  /// Set when the user pinned a server via `foo:{hosted: <url>}`. This
  /// bypasses the multi-server search and any `--server` flag for the
  /// individual package.
  final String? explicitHostedUrl;

  /// Original descriptor text (for diagnostics).
  final String? rawDescriptor;
}

/// Options consumed by [AddRunner.run].
class AddOptions {
  AddOptions({
    required this.args,
    this.directory = '',
    this.dryRun = false,
    this.serverFlag,
  });

  /// Raw positional args — one per `<package>[:<descriptor>]` token.
  final List<String> args;

  /// `-C/--directory`. Resolves to cwd when empty.
  final String directory;

  /// `--dry-run/-n`.
  final bool dryRun;

  /// `--server/-s` — forces a single club server for every request that does
  /// not carry its own `{hosted: ...}` pin.
  final String? serverFlag;
}
