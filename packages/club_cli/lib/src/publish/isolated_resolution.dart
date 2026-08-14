/// Resolves a package's dependencies in isolation, away from its workspace.
///
/// `dart pub publish` resolves the *workspace* before publishing. For club
/// that is the wrong question to ask. A published package is consumed on its
/// own: the archive is unpacked into the pub cache and resolved against
/// whatever the consumer already has. Resolving the developer's workspace
/// instead means
///
///   - the workspace root's `dependency_overrides` (often local `path:`
///     overrides) silently stand in for the real hosted versions, so the check
///     passes on a machine where the published package would not resolve; and
///   - an unrelated dependency problem anywhere else in the workspace blocks
///     publishing a leaf package.
///
/// It also cannot work at all when the workspace root needs the Flutter SDK
/// but the package being published does not (or vice versa), because pub
/// escalates resolution to the workspace root.
///
/// So we resolve what actually ships: unpack the built archive into a scratch
/// directory, drop the `resolution: workspace` marker (meaningless outside the
/// workspace, and pub errors out if it cannot find a root), and run `pub get`
/// there. The archive itself is never modified — `resolution: workspace` is a
/// normal thing to find in a published pubspec and consumers ignore it.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../util/ensure_pub_token.dart';
import '../util/log.dart';
import '../util/pub_tool.dart';
import '../util/url.dart';
import 'pubspec_reader.dart';

/// Outcome of [resolveInIsolation].
class IsolatedResolution {
  IsolatedResolution({required this.ok, required this.directory});

  /// False when `pub get` failed. The error has already been printed.
  final bool ok;

  /// The scratch directory the archive was unpacked into, or `null` when
  /// extraction itself failed. Non-null even when [ok] is false, so callers
  /// can still inspect it.
  ///
  /// Caller must pass this to [disposeIsolatedResolution] when done.
  final Directory? directory;
}

/// Unpacks [archivePath] and resolves its dependencies in a scratch directory.
///
/// [pubspec] is the package being published; it decides whether `dart pub` or
/// `flutter pub` is used, and whether a pub token needs registering for
/// [serverUrl] first.
///
/// [serverToken] is registered with pub for [serverUrl] when the pubspec has
/// dependencies hosted there — without it, `pub get` in a scratch directory
/// (which has no lockfile to fall back on) fails with an opaque auth error.
Future<IsolatedResolution> resolveInIsolation({
  required String archivePath,
  required PackagePubspec pubspec,
  required String serverUrl,
  required String? serverToken,
  required Future<Directory> Function(String archivePath) extract,
  String? errorHint,
}) async {
  heading('Resolving dependencies');
  final sw = Stopwatch()..start();

  final Directory dir;
  try {
    dir = await extract(archivePath);
  } on Object catch (e) {
    sw.stop();
    error('Could not unpack the package archive for resolution.\n  $e');
    return IsolatedResolution(ok: false, directory: null);
  }

  final stripped = stripWorkspaceMarkers(p.join(dir.path, 'pubspec.yaml'));
  final pruned = pruneNestedPackages(dir);
  final notes = <String>[
    if (stripped) 'workspace markers dropped',
    if (pruned.isNotEmpty)
      '${pruned.length} nested '
          '${pruned.length == 1 ? 'package' : 'packages'} excluded '
          '(${pruned.join(', ')})',
  ];
  detail(
    gray(
      'unpacked to ${dir.path}'
      '${notes.isEmpty ? '' : ' (${notes.join('; ')})'}',
    ),
  );

  if (serverToken != null && _hasDepHostedOn(pubspec.parsed, serverUrl)) {
    await ensureDartPubToken(serverUrl, serverToken);
  }

  final tool = pubToolFor(pubspec.parsed);
  final result = await runPub(['get'], workingDirectory: dir.path, tool: tool);
  sw.stop();

  if (result.toolMissing) {
    detail(
      yellow('Skipped') +
          gray(' (could not locate `${result.tool.executable}` on PATH)'),
    );
    return IsolatedResolution(ok: true, directory: dir);
  }

  if (result.ok) {
    detail(
      '${green('✓')} Resolved standalone with '
      '${gray('`${result.tool.executable} pub get`')} '
      '${gray('(${formatDuration(sw.elapsed)})')}',
    );
    return IsolatedResolution(ok: true, directory: dir);
  }

  final indented = result.output.split('\n').map((l) => '  $l').join('\n');
  error(
    'Dependency resolution failed.\n'
    '${pubspec.name} ${pubspec.version} was resolved on its own, the way a '
    'consumer would get it — not inside its workspace.'
    '${errorHint == null ? '' : '\n$errorHint'}\n$indented',
  );
  for (final h in _hintsFor(pubspec.parsed, serverUrl)) {
    hint(h);
  }
  return IsolatedResolution(ok: false, directory: dir);
}

/// Deletes the scratch directory created by [resolveInIsolation].
void disposeIsolatedResolution(Directory? dir) {
  if (dir == null) return;
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Best-effort cleanup; the OS reaps the temp dir eventually.
  }
}

/// Removes `resolution:` and `workspace:` from the pubspec at [path].
///
/// Returns true if anything was removed. `resolution: workspace` makes pub
/// walk up looking for a workspace root, which does not exist in a scratch
/// directory. `workspace:` would make the scratch copy a workspace root whose
/// members are missing.
bool stripWorkspaceMarkers(String path) {
  final file = File(path);
  if (!file.existsSync()) return false;

  final editor = YamlEditor(file.readAsStringSync());
  var changed = false;
  for (final key in const ['resolution', 'workspace']) {
    try {
      editor.remove([key]);
      changed = true;
    } on ArgumentError {
      // Key absent — nothing to strip.
    }
  }
  if (changed) file.writeAsStringSync(editor.toString());
  return changed;
}

/// Removes nested packages from the scratch copy at [dir], returning their
/// paths relative to [dir], sorted.
///
/// A published archive routinely carries an `example/` package, and pub
/// resolves *every* package it finds beneath the directory it runs in. A
/// nested package cannot resolve from inside an archive:
///
///   - its `resolution: workspace` marker needs a workspace root, which is
///     not in the archive (this fails before resolution even starts); and
///   - its `path:` dependencies point at siblings that only exist in the
///     developer's checkout.
///
/// Neither is part of what a consumer resolves when they depend on this
/// package, so an unresolvable example must not fail the publish. Leaving one
/// in place also makes `dart analyze` report every unresolved import in it as
/// an error against the package being published.
///
/// Only the scratch copy is pruned. The archive that uploads is untouched, so
/// consumers still receive the example.
List<String> pruneNestedPackages(Directory dir) {
  final pruned = <String>[];

  void walk(Directory current) {
    final List<FileSystemEntity> entries;
    try {
      entries = current.listSync(followLinks: false);
    } on FileSystemException {
      return; // Unreadable directory; nothing we can prune in it.
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      if (p.basename(entry.path) == '.dart_tool') continue;

      if (File(p.join(entry.path, 'pubspec.yaml')).existsSync()) {
        pruned.add(p.relative(entry.path, from: dir.path));
        try {
          entry.deleteSync(recursive: true);
        } on FileSystemException {
          // Could not remove it; resolution may still fail, but continuing
          // gives a real pub error rather than an error from us.
        }
        continue; // Never descend into what we just removed.
      }
      walk(entry);
    }
  }

  walk(dir);
  pruned.sort();
  return pruned;
}

/// True when any dependency or dev_dependency is hosted on [serverUrl].
bool _hasDepHostedOn(Pubspec parsed, String serverUrl) {
  final target = _canonical(serverUrl);
  if (target == null) return false;

  bool matches(Dependency dep) {
    if (dep is! HostedDependency) return false;
    final url = dep.hosted?.url;
    if (url == null) return false;
    return _canonical(url.toString()) == target;
  }

  return parsed.dependencies.values.any(matches) ||
      parsed.devDependencies.values.any(matches);
}

String? _canonical(String url) {
  try {
    return parseServerInput(url);
  } on FormatException {
    return null;
  }
}

/// Extra guidance for the common ways a standalone resolve fails where a
/// workspace resolve would have succeeded.
List<String> _hintsFor(Pubspec parsed, String serverUrl) {
  final hints = <String>[];

  final nonHosted = <String>[
    for (final e in parsed.dependencies.entries)
      if (e.value is PathDependency || e.value is GitDependency) e.key,
  ];
  if (nonHosted.isNotEmpty) {
    hints.add(
      'These dependencies are not hosted, so they cannot resolve outside '
      'your checkout: ${nonHosted.join(', ')}.\n'
      'Publish them first and switch to hosted refs, or use '
      '`club publish --auto` / `club prepare` to rewrite them for you.',
    );
  }

  if (_hasDepHostedOn(parsed, serverUrl)) {
    hints.add(
      'If the failure looks like an auth error, run '
      '`club login --server ${displayServer(serverUrl)}` and retry.',
    );
  }

  return hints;
}
