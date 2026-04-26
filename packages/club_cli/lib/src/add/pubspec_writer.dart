/// Writes resolved club dependencies into pubspec.yaml.
///
/// Uses `package:yaml_edit` for round-trip-safe edits: comments, key order,
/// and surrounding whitespace are preserved. Every entry is written as an
/// explicit hosted block:
///
///     foo:
///       hosted: https://club.example.com
///       version: ^1.2.3
///
/// This is the same shape `dart pub add --hosted=<url> foo` produces and it
/// binds the dependency to the chosen server even if `PUB_HOSTED_URL`
/// changes later.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml_edit/yaml_edit.dart';

import 'package_resolver.dart';

/// One applied pubspec change (for dry-run / summary output).
class AppliedChange {
  AppliedChange({
    required this.resolved,
    required this.action,
    required this.constraint,
  });

  final ResolvedPackage resolved;

  /// `added` for a new entry, `updated` when the dependency already existed.
  final String action;
  final String constraint;
}

/// Apply every [ResolvedPackage] to the pubspec at [packageDir].
///
/// When [dryRun] is true the file is not touched; the caller uses the
/// returned [AppliedChange] list to show what would change.
class PubspecWriter {
  PubspecWriter({required this.packageDir, required this.dryRun});

  final String packageDir;
  final bool dryRun;

  Future<List<AppliedChange>> apply(List<ResolvedPackage> resolved) async {
    // Caller guarantees pubspec.yaml exists (see AddRunner).
    final file = File(p.join(packageDir, 'pubspec.yaml'));
    final raw = file.readAsStringSync();
    final editor = YamlEditor(raw);
    final changes = <AppliedChange>[];

    for (final r in resolved) {
      changes.add(_applyOne(editor, r));
    }

    if (!dryRun) {
      // yaml_edit emits deterministic output — no trailing-newline issues.
      file.writeAsStringSync(editor.toString());
    }
    return changes;
  }

  AppliedChange _applyOne(YamlEditor editor, ResolvedPackage resolved) {
    final sectionKey = resolved.request.section.key;
    _ensureMap(editor, sectionKey);

    final constraint = resolved.constraintString;
    final value = <String, Object?>{
      'hosted': resolved.serverUrl,
      'version': constraint,
    };

    final existedBefore = _hasPath(editor, [sectionKey, resolved.request.name]);
    editor.update([sectionKey, resolved.request.name], value);

    return AppliedChange(
      resolved: resolved,
      action: existedBefore ? 'updated' : 'added',
      constraint: constraint,
    );
  }

  /// yaml_edit requires the parent map to exist before `update` can create
  /// a child key. `pubspec.yaml` may lack `dev_dependencies:` or
  /// `dependency_overrides:`, so create them on demand as empty maps.
  void _ensureMap(YamlEditor editor, String key) {
    if (_hasPath(editor, [key])) return;
    editor.update([key], <String, Object?>{});
  }

  bool _hasPath(YamlEditor editor, List<Object> path) {
    try {
      final node = editor.parseAt(path);
      // A null scalar counts as absent — e.g. `dev_dependencies:` with no
      // body parses as null, not as an empty map, and we need to replace it.
      return node.value != null;
    } on ArgumentError {
      return false;
    } on StateError {
      // yaml_edit throws PathError (a StateError) when the path traverses
      // into a non-map node. Treat that as "absent" so the caller can
      // rewrite it as an empty map.
      return false;
    }
  }
}
