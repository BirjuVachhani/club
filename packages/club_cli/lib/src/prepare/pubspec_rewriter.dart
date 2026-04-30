/// Applies [PackagePlan]s to pubspec.yaml files on disk.
///
/// Uses `package:yaml_edit` for round-trip-safe edits — comments, key order,
/// and surrounding whitespace are preserved. Mirrors `add/pubspec_writer.dart`.
///
/// `applyPlans` runs the full batch as a two-phase commit: every editor
/// string is built in memory first, then files are written sequentially.
/// This means a malformed-edit failure can never half-rewrite the workspace,
/// and writes use the [DiscoveredPackage.rawYaml] captured during discovery
/// rather than re-reading from disk (no TOCTOU window).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml_edit/yaml_edit.dart';

import '../util/yaml_utils.dart';
import 'rewrite_planner.dart';

/// Build the new YAML string for [plan]. Returns `null` when the plan has
/// no rewrites (caller can skip writing the file).
String? buildRewrittenYaml(PackagePlan plan) {
  if (plan.rewrites.isEmpty) return null;

  final editor = YamlEditor(plan.package.rawYaml);
  for (final r in plan.rewrites) {
    ensureMapNode(editor, r.section.key);
    editor.update([r.section.key, r.depName], <String, Object?>{
      'hosted': r.serverUrl,
      'version': r.constraint,
    });
  }
  return editor.toString();
}

/// Apply [plans] in a two-phase commit.
///
/// Phase 1: build every new YAML string in memory (any
/// `yaml_edit`/format error aborts here, before touching disk).
/// Phase 2: write the new contents back to each pubspec.yaml.
///
/// When [dryRun] is true, phase 1 still runs (so format errors surface
/// during preview) but phase 2 is skipped.
///
/// Returns the number of files that were modified (or would have been).
int applyPlans(List<PackagePlan> plans, {required bool dryRun}) {
  final pending = <_PendingWrite>[];
  for (final plan in plans) {
    final next = buildRewrittenYaml(plan);
    if (next == null) continue;
    pending.add(
      _PendingWrite(
        path: p.join(plan.package.directory, 'pubspec.yaml'),
        contents: next,
      ),
    );
  }

  if (!dryRun) {
    for (final w in pending) {
      File(w.path).writeAsStringSync(w.contents);
    }
  }
  return pending.length;
}

class _PendingWrite {
  _PendingWrite({required this.path, required this.contents});
  final String path;
  final String contents;
}
