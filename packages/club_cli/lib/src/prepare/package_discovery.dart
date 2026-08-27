/// Discovers all publishable Dart packages under a root directory.
///
/// Walks the file tree from [rootDir] looking for `pubspec.yaml` or `pubspec.yml` files,
/// skipping ignored conventional directories (`.git`, `.dart_tool`, `build`,
/// `node_modules`, hidden dirs). Each pubspec is parsed; pubspecs without a
/// `name` or `version` (typical of pub workspace roots and umbrella manifests)
/// are dropped because they cannot participate in a publish dependency graph.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import '../publish/pr_version.dart';

/// One package found by [discoverPackages].
class DiscoveredPackage {
  DiscoveredPackage({
    required this.directory,
    required this.pubspecPath,
    required this.pubspec,
    required this.rawYaml,
    this.versionOverride,
  });

  /// Absolute, canonicalized path to the package directory.
  final String directory;

  /// Absolute path to the discovered `pubspec.yaml` or `pubspec.yml`.
  final String pubspecPath;

  /// Parsed pubspec. May lack a `version:` field — that is only required
  /// for packages that end up in a publish closure, and the planner is
  /// responsible for surfacing a clear error in that case.
  final Pubspec pubspec;

  /// Raw pubspec contents (preserved for downstream rewriters).
  final String rawYaml;

  /// When set, replaces the pubspec's own version everywhere this package's
  /// version is consulted: the constraint written into dependents, the
  /// already-published check, and the publish stack display. Mirrors
  /// `PackagePubspec.versionOverride`; source files are never modified.
  final String? versionOverride;

  String get name => pubspec.name;

  /// Pubspec version as a string, or `null` when the pubspec has no
  /// `version:` field.
  String? get version => versionOverride ?? pubspec.version?.toString();
}

/// Directory names that should never be descended into during discovery.
const _skipDirs = {
  '.git',
  '.dart_tool',
  '.pub-cache',
  'build',
  'node_modules',
  '.idea',
  '.vscode',
};

/// Walk [rootDir] and return every package whose pubspec has both a name and
/// a version. Result is keyed by package name.
///
/// [versionSuffix], when set, is applied to every discovered package's
/// version as a prerelease identifier (see [applyPrereleaseSuffix]). This is
/// how `--from-git <pr-url> --auto` publishes a whole monorepo stack as
/// `-pr<n>` builds: because dependent constraints and the already-published
/// check both read [DiscoveredPackage.version], suffixing here keeps the
/// stack internally consistent, with siblings resolving to `^X.Y.Z-pr<n>`.
///
/// [versionOverride] instead replaces every package's version outright,
/// which is how `--version` publishes a whole stack as one version. It wins
/// over [versionSuffix]: a version the user named is used verbatim.
///
/// Throws [FormatException] when two discovered packages share the same
/// `name`, since a graph keyed by name cannot disambiguate them.
Map<String, DiscoveredPackage> discoverPackages(
  String rootDir, {
  String? versionSuffix,
  String? versionOverride,
}) {
  final root = Directory(p.absolute(rootDir));
  if (!root.existsSync()) {
    throw FileSystemException('Directory not found', root.path);
  }

  final found = <String, DiscoveredPackage>{};
  final duplicates = <String, List<String>>{};

  void walk(Directory dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      // Permission errors etc. — skip silently.
      return;
    }

    File? yamlPubspec;
    File? ymlPubspec;
    final subdirs = <Directory>[];
    for (final e in entries) {
      final base = p.basename(e.path);
      if (e is File && base == 'pubspec.yaml') {
        yamlPubspec = e;
      } else if (e is File && base == 'pubspec.yml') {
        ymlPubspec = e;
      } else if (e is Directory) {
        if (base.startsWith('.') || _skipDirs.contains(base)) continue;
        subdirs.add(e);
      }
    }

    if (yamlPubspec != null && ymlPubspec != null) {
      throw FormatException(
        'Both pubspec.yaml and pubspec.yml exist in ${dir.path}.',
      );
    }

    final pubspec = yamlPubspec ?? ymlPubspec;
    if (pubspec != null) {
      final raw = pubspec.readAsStringSync();
      try {
        final parsed = Pubspec.parse(raw, sourceUrl: pubspec.uri);
        // Skip workspace umbrella manifests: a pubspec that lists
        // workspace members is the root, not a publishable package.
        final isWorkspaceRoot =
            parsed.workspace != null && parsed.workspace!.isNotEmpty;
        if (!isWorkspaceRoot) {
          final baseVersion = parsed.version?.toString();
          final pkg = DiscoveredPackage(
            directory: p.canonicalize(dir.path),
            pubspecPath: p.canonicalize(pubspec.path),
            pubspec: parsed,
            rawYaml: raw,
            versionOverride:
                versionOverride ??
                (versionSuffix == null || baseVersion == null
                    ? null
                    : applyPrereleaseSuffix(baseVersion, versionSuffix)),
          );
          final existing = found[parsed.name];
          if (existing != null) {
            duplicates
                .putIfAbsent(parsed.name, () => [existing.directory])
                .add(pkg.directory);
          } else {
            found[parsed.name] = pkg;
          }
        }
      } on Exception {
        // Malformed pubspec — skip; an explicit `club publish` against it
        // will surface the parse error properly.
      }
    }

    for (final s in subdirs) {
      walk(s);
    }
  }

  walk(root);

  if (duplicates.isNotEmpty) {
    final lines = <String>[
      'Multiple packages with the same name were found in the workspace:',
    ];
    duplicates.forEach((name, dirs) {
      lines.add('  $name:');
      for (final d in dirs) {
        lines.add('    - $d');
      }
    });
    throw FormatException(lines.join('\n'));
  }

  return found;
}
