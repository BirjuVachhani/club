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

import '../util/yaml_utils.dart';
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
    ensureMapNode(editor, sectionKey);

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

  bool _hasPath(YamlEditor editor, List<Object> path) {
    try {
      final node = editor.parseAt(path);
      return node.value != null;
    } on ArgumentError {
      return false;
    } on StateError {
      return false;
    }
  }
}
