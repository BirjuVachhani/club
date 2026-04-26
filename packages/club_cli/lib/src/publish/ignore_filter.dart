/// File-inclusion filter for `club publish`.
///
/// Byte-compatible with dart pub's
/// [`Package.listFiles`](https://github.com/dart-lang/pub/blob/master/lib/src/package.dart).
/// Concretely:
/// - Walk starts at the package root, but paths are resolved relative to the
///   enclosing git repository root (if one exists) so `.gitignore` / `.pubignore`
///   files above the package can still be honoured.
/// - In each directory, `.pubignore` takes precedence over `.gitignore`.
/// - At the package root we additionally apply pub's `_basicIgnoreRules`:
///   all dotfiles (`.*`) except `.htaccess`, `pubspec.lock` (file only), and
///   `pubspec_overrides.yaml` (anchored to the package root).
/// - Pattern matching is case-insensitive on macOS / Windows to mirror
///   `core.ignoreCase = true` which `git init` / `git clone` set by default
///   on those platforms.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'vendor/ignore.dart';

/// Rules pub always applies at the package root.
const _basicIgnoreRules = [
  '.*', // Don't include dot-files.
  '!.htaccess', // Include .htaccess anyways.
  'pubspec.lock',
  '!pubspec.lock/', // We allow a directory called pubspec.lock.
  '/pubspec_overrides.yaml',
];

/// Decides which files under a package root ship in the published tarball.
class IgnoreFilter {
  IgnoreFilter._({
    required String repoRoot,
    required String beneath,
    required bool caseInsensitive,
  }) : _repoRoot = repoRoot,
       _beneath = beneath,
       _caseInsensitive = caseInsensitive;

  /// Absolute path used as the root for ignore-rule resolution. Equal to
  /// the enclosing git repo root when the package is in a git repo,
  /// otherwise equal to the package root.
  final String _repoRoot;

  /// [_packageRoot] expressed relative to [_repoRoot] in POSIX form —
  /// this is the `beneath` value handed to [Ignore.listFiles].
  final String _beneath;

  /// Case-insensitive pattern matching? Defaults to true on macOS/Windows.
  final bool _caseInsensitive;

  /// Build an ignore filter for the package at [packageRoot].
  factory IgnoreFilter.forPackage(String packageRoot) {
    // Canonicalise to resolve symlinks (notably /tmp → /private/tmp on
    // macOS) so the repo-root-relative path doesn't come out as
    // `../../../tmp/...`.
    final absPackage = _canonicalize(p.absolute(packageRoot));
    final rawRepoRoot = _gitRepoRoot(absPackage);
    final repoRoot = rawRepoRoot == null
        ? absPackage
        : _canonicalize(rawRepoRoot);
    var beneath = p
        .toUri(
          p.normalize(p.relative(absPackage, from: repoRoot)),
        )
        .path;
    if (beneath == './' || beneath.isEmpty) beneath = '.';
    return IgnoreFilter._(
      repoRoot: repoRoot,
      beneath: beneath,
      caseInsensitive: Platform.isMacOS || Platform.isWindows,
    );
  }

  /// Recursively list every file under the package root that should be
  /// included in the published archive. Returns POSIX paths **relative to
  /// the package root** (e.g. `lib/foo.dart`, `pubspec.yaml`).
  List<String> listFiles() {
    String resolve(String path) {
      if (Platform.isWindows) {
        return p.joinAll([_repoRoot, ...p.posix.split(path)]);
      }
      return p.join(_repoRoot, path);
    }

    final repoRelative = Ignore.listFiles(
      beneath: _beneath,
      listDir: (dir) {
        final absDir = resolve(dir);
        if (!Directory(absDir).existsSync()) return const [];
        return Directory(absDir).listSync(followLinks: false).map((entity) {
          final rel = p.relative(entity.path, from: _repoRoot);
          if (Platform.isWindows) {
            return p.posix.joinAll(p.split(rel));
          }
          return rel;
        });
      },
      ignoreForDir: (dir) {
        final pubIgnore = File(resolve('$dir/.pubignore'));
        final gitIgnore = File(resolve('$dir/.gitignore'));
        final source = pubIgnore.existsSync()
            ? pubIgnore
            : (gitIgnore.existsSync() ? gitIgnore : null);

        final rules = <String>[
          // Only at the package root: layer in pub's always-excluded set.
          if (dir == _beneath) ..._basicIgnoreRules,
          if (source != null) source.readAsStringSync(),
        ];
        return rules.isEmpty
            ? null
            : Ignore(rules, ignoreCase: _caseInsensitive);
      },
      isDir: (dir) => Directory(resolve(dir)).existsSync(),
    );

    // Convert repo-relative POSIX paths to package-relative POSIX paths.
    // [_beneath] is `.` when package == repo root, otherwise e.g.
    // `packages/club_core`. Each repo-relative entry starts with
    // `$_beneath/` in that case; strip the prefix.
    final packageRelative = <String>[];
    final prefix = _beneath == '.' ? '' : '$_beneath/';
    for (final rel in repoRelative) {
      if (prefix.isEmpty) {
        packageRelative.add(rel);
      } else if (rel.startsWith(prefix)) {
        packageRelative.add(rel.substring(prefix.length));
      } else {
        // Shouldn't happen (Ignore.listFiles only returns entries under
        // beneath), but guard anyway.
        packageRelative.add(rel);
      }
    }
    packageRelative.sort();
    return packageRelative;
  }
}

String? _gitRepoRoot(String dir) {
  try {
    final r = Process.runSync(
      'git',
      ['rev-parse', '--show-toplevel'],
      workingDirectory: dir,
    );
    if (r.exitCode != 0) return null;
    final out = (r.stdout as String).trim();
    return out.isEmpty ? null : out;
  } on ProcessException {
    return null;
  }
}

/// Resolves symlinks in [path] so `/tmp/foo` and `/private/tmp/foo` compare
/// as equal on macOS. Falls back to normalised input when the path doesn't
/// exist (e.g. during tests against a path we haven't created yet).
String _canonicalize(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(path);
  }
}
