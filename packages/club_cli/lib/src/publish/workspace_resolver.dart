/// Locates the workspace root of a package being published.
///
/// Mirrors the role of dart pub's
/// [`Entrypoint._loadWorkspace`](https://github.com/dart-lang/pub/blob/master/lib/src/entrypoint.dart):
/// walk up from the package directory looking for a `pubspec.yaml` without
/// `resolution: workspace`. That pubspec is the workspace root. Validate that
/// its `workspace:` list actually includes the package being published (so we
/// catch half-configured workspaces early instead of publishing garbage).
///
/// We only care about workspace resolution for the *work* package — the one
/// being published. Sibling members and the resolver's lock file are
/// irrelevant to producing a correct tarball, since dart pub's published
/// archive contains only the work package directory.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

/// Result of resolving a workspace for a package.
class WorkspaceContext {
  WorkspaceContext({
    required this.workPackageDir,
    required this.workspaceRootDir,
  });

  /// Absolute path of the package being published (the "work" package).
  final String workPackageDir;

  /// Absolute path of the workspace root pubspec's directory, or `null` when
  /// the work package is not part of a workspace.
  final String? workspaceRootDir;

  /// True if the work package is part of a pub workspace.
  bool get isWorkspaceMember => workspaceRootDir != null;
}

/// Raised when a workspace member's root cannot be located or does not
/// declare this member in its `workspace:` list.
class WorkspaceResolutionError implements Exception {
  WorkspaceResolutionError(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => message;
}

/// Resolve the workspace context for the package at [workPackageDir].
///
/// If [workPackageResolution] is not `workspace`, returns a
/// [WorkspaceContext] with [WorkspaceContext.workspaceRootDir] set to `null`.
///
/// If it *is* `workspace`, walks up parent directories until a `pubspec.yaml`
/// without `resolution: workspace` is found. Then verifies that root
/// pubspec's `workspace:` list resolves (via globs, just like dart pub) to a
/// set that contains [workPackageDir].
///
/// Throws [WorkspaceResolutionError] on any failure.
WorkspaceContext resolveWorkspace({
  required String workPackageDir,
  required String? workPackageResolution,
}) {
  final absWork = p.absolute(workPackageDir);
  if (workPackageResolution != 'workspace') {
    return WorkspaceContext(workPackageDir: absWork, workspaceRootDir: null);
  }

  String? current = p.dirname(absWork);
  // Stop when we've walked past the filesystem root.
  while (current != null && current.isNotEmpty) {
    final candidate = File(p.join(current, 'pubspec.yaml'));
    if (candidate.existsSync()) {
      final Pubspec parent;
      try {
        parent = Pubspec.parse(candidate.readAsStringSync());
      } on Exception catch (e) {
        throw WorkspaceResolutionError(
          'Failed to parse potential workspace root at ${candidate.path}: $e',
        );
      }
      if (parent.resolution != 'workspace') {
        _verifyRootIncludesMember(
          rootDir: current,
          rootWorkspace: parent.workspace ?? const [],
          workPackageDir: absWork,
        );
        return WorkspaceContext(
          workPackageDir: absWork,
          workspaceRootDir: current,
        );
      }
      // Parent is also a workspace member — keep walking.
    }
    final next = p.dirname(current);
    if (next == current) break; // filesystem root
    current = next;
  }

  throw WorkspaceResolutionError(
    'This package declares `resolution: workspace` but no workspace root '
    'was found in parent directories.',
    hint:
        'Create a pubspec.yaml in a parent directory with a `workspace:` '
        'entry that includes this package, or remove `resolution: workspace` '
        'from this pubspec.',
  );
}

void _verifyRootIncludesMember({
  required String rootDir,
  required List<String> rootWorkspace,
  required String workPackageDir,
}) {
  if (rootWorkspace.isEmpty) {
    throw WorkspaceResolutionError(
      'Workspace root at ${p.join(rootDir, 'pubspec.yaml')} does not '
      'declare a `workspace:` list, but this package has '
      '`resolution: workspace`.',
      hint:
          'Add this package\'s relative path to the root pubspec\'s '
          '`workspace:` list.',
    );
  }

  final canonicalWork = p.canonicalize(workPackageDir);
  for (final entry in rootWorkspace) {
    if (_looksLikeGlob(entry)) {
      final pattern = entry.replaceAll(r'\', '/');
      final matcher = Glob(pattern, context: p.posix);
      for (final match in matcher.listSync(root: rootDir)) {
        if (match is Directory && p.canonicalize(match.path) == canonicalWork) {
          return;
        }
      }
    } else {
      final candidate = p.join(rootDir, entry);
      if (p.canonicalize(candidate) == canonicalWork) return;
    }
  }

  throw WorkspaceResolutionError(
    'Workspace root at ${p.join(rootDir, 'pubspec.yaml')} does not include '
    '${p.relative(workPackageDir, from: rootDir)} in its `workspace:` list.',
    hint:
        'Add "${p.relative(workPackageDir, from: rootDir)}" to the '
        'root pubspec\'s `workspace:` list, or remove `resolution: workspace` '
        'from this package.',
  );
}

bool _looksLikeGlob(String s) =>
    s.contains('*') || s.contains('?') || s.contains('[') || s.contains('{');
