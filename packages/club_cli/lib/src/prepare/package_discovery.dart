/// Discovers all publishable Dart packages under a root directory.
///
/// Walks the file tree from [rootDir] looking for `pubspec.yaml` files,
/// skipping ignored conventional directories (`.git`, `.dart_tool`, `build`,
/// `node_modules`, hidden dirs). Each pubspec is parsed; pubspecs without a
/// `name` or `version` (typical of pub workspace roots and umbrella manifests)
/// are dropped because they cannot participate in a publish dependency graph.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

/// One package found by [discoverPackages].
class DiscoveredPackage {
  DiscoveredPackage({
    required this.directory,
    required this.pubspec,
    required this.rawYaml,
  });

  /// Absolute, canonicalized path to the package directory.
  final String directory;

  /// Parsed pubspec. May lack a `version:` field — that is only required
  /// for packages that end up in a publish closure, and the planner is
  /// responsible for surfacing a clear error in that case.
  final Pubspec pubspec;

  /// Raw pubspec.yaml contents (preserved for downstream rewriters).
  final String rawYaml;

  String get name => pubspec.name;

  /// Pubspec version as a string, or `null` when the pubspec has no
  /// `version:` field.
  String? get version => pubspec.version?.toString();
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
/// Throws [FormatException] when two discovered packages share the same
/// `name`, since a graph keyed by name cannot disambiguate them.
Map<String, DiscoveredPackage> discoverPackages(String rootDir) {
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

    File? pubspec;
    final subdirs = <Directory>[];
    for (final e in entries) {
      final base = p.basename(e.path);
      if (e is File && base == 'pubspec.yaml') {
        pubspec = e;
      } else if (e is Directory) {
        if (base.startsWith('.') || _skipDirs.contains(base)) continue;
        subdirs.add(e);
      }
    }

    if (pubspec != null) {
      final raw = pubspec.readAsStringSync();
      try {
        final parsed = Pubspec.parse(raw, sourceUrl: pubspec.uri);
        // Skip workspace umbrella manifests: a pubspec that lists
        // workspace members is the root, not a publishable package.
        final isWorkspaceRoot =
            parsed.workspace != null && parsed.workspace!.isNotEmpty;
        if (!isWorkspaceRoot) {
          final pkg = DiscoveredPackage(
            directory: p.canonicalize(dir.path),
            pubspec: parsed,
            rawYaml: raw,
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
