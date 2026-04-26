/// Mirrors dart pub's
/// [`DependencyOverrideValidator`](https://github.com/dart-lang/pub/blob/master/lib/src/validator/dependency_override.dart):
/// hints when any of the transitive non-dev dependencies of this package is
/// overridden anywhere in the workspace. Overrides aren't respected by
/// downstream consumers, so testing under overrides is lying to yourself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:yaml/yaml.dart';

import 'validator.dart';

class DependencyOverrideValidator extends Validator {
  DependencyOverrideValidator(super.context);

  @override
  String get name => 'DependencyOverrideValidator';

  @override
  Future<void> validate() async {
    // Build the transitive non-dev dep closure for the current package via
    // `dart pub deps --json`, which reflects the resolver's actual graph.
    final closure = await _transitiveNonDevClosure();
    if (closure == null || closure.isEmpty) return;

    final wsPackages = _workspacePackageDirs();
    for (final dir in wsPackages) {
      final pubspecPath = p.join(dir, 'pubspec.yaml');
      final overridesPath = p.join(dir, 'pubspec_overrides.yaml');
      final overrides = _readOverrides(pubspecPath, overridesPath);
      for (final entry in overrides.entries) {
        if (!closure.contains(entry.key)) continue;
        final sourceFile = entry.value;
        hint(
          'Non-dev dependencies are overridden in $sourceFile.\n\n'
          'This indicates you are not testing your package against the '
          'same versions of its\ndependencies that users will have when '
          'they use it.\n\n'
          'This might be necessary for packages with cyclic dependencies.'
          '\n\nPlease be extra careful when publishing.',
        );
      }
    }
  }

  /// Returns the set of transitive non-dev dep names reachable from the
  /// current package via pub's resolved graph. `null` if we can't compute
  /// (Dart SDK missing, parse error, etc.).
  Future<Set<String>?> _transitiveNonDevClosure() async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'dart',
        ['pub', 'deps', '--json'],
        workingDirectory: context.pubspec.directory,
      );
    } on ProcessException {
      return null;
    }
    if (result.exitCode != 0) return null;

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final packages = data['packages'];
    if (packages is! List) return null;

    final byName = <String, Map<String, dynamic>>{};
    for (final p in packages) {
      if (p is Map<String, dynamic>) byName[p['name'] as String] = p;
    }

    final closure = <String>{};
    final queue = <String>[context.pubspec.name];
    while (queue.isNotEmpty) {
      final next = queue.removeLast();
      if (!closure.add(next)) continue;
      final node = byName[next];
      if (node == null) continue;
      // `directDependencies` is the package's non-dev deps per the pub deps
      // JSON schema. `dependencies` also includes dev_dependencies for the
      // root, so we use `directDependencies` for correctness.
      final direct = node['directDependencies'];
      if (direct is List) queue.addAll(direct.cast<String>());
    }
    return closure;
  }

  /// Walks the workspace (if any) and returns every package directory,
  /// including the current package. Falls back to just the current package
  /// when not in a workspace.
  List<String> _workspacePackageDirs() {
    final rootDir = context.workspaceRootDir;
    if (rootDir == null) return [context.pubspec.directory];

    final result = <String>{rootDir};
    final queue = [rootDir];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      final pubspec = File(p.join(dir, 'pubspec.yaml'));
      if (!pubspec.existsSync()) continue;
      try {
        final parsed = Pubspec.parse(pubspec.readAsStringSync());
        for (final entry in parsed.workspace ?? const <String>[]) {
          if (_looksLikeGlob(entry)) {
            // Resolve glob matches by listing the parent directory.
            final parent = p.join(dir, p.dirname(entry));
            final pattern = p.basename(entry);
            if (!Directory(parent).existsSync()) continue;
            for (final child in Directory(parent).listSync()) {
              if (child is! Directory) continue;
              if (!_globMatches(pattern, p.basename(child.path))) continue;
              if (result.add(child.path)) queue.add(child.path);
            }
          } else {
            final abs = p.normalize(p.join(dir, entry));
            if (result.add(abs)) queue.add(abs);
          }
        }
      } on Exception {
        // skip unparseable pubspec
      }
    }
    return result.toList();
  }

  /// Reads dependency override keys from a package's pubspec (plus optional
  /// `pubspec_overrides.yaml`). Returns a map of `dep name -> file where
  /// override lives` so the hint can cite the source accurately.
  Map<String, String> _readOverrides(String pubspecPath, String overridesPath) {
    final result = <String, String>{};

    // pubspec_overrides.yaml wins (dart pub convention).
    final overridesFile = File(overridesPath);
    if (overridesFile.existsSync()) {
      final yaml = loadYaml(overridesFile.readAsStringSync());
      if (yaml is Map && yaml['dependency_overrides'] is Map) {
        for (final key in (yaml['dependency_overrides'] as Map).keys) {
          result[key.toString()] = overridesPath;
        }
      }
      // If pubspec_overrides.yaml exists, pubspec.yaml overrides are
      // ignored by pub. Match that.
      if (result.isNotEmpty) return result;
    }

    final pubspecFile = File(pubspecPath);
    if (!pubspecFile.existsSync()) return result;
    final yaml = loadYaml(pubspecFile.readAsStringSync());
    if (yaml is Map && yaml['dependency_overrides'] is Map) {
      for (final key in (yaml['dependency_overrides'] as Map).keys) {
        result[key.toString()] = pubspecPath;
      }
    }
    return result;
  }

  bool _looksLikeGlob(String s) =>
      s.contains('*') || s.contains('?') || s.contains('[');

  bool _globMatches(String pattern, String name) {
    // Only `*` wildcard is supported — matches dart pub's practical usage.
    final regex = RegExp(
      '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
    );
    return regex.hasMatch(name);
  }
}
