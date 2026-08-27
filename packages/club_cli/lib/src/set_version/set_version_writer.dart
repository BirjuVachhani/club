/// Applies a set-version plan while preserving pubspec formatting.
library;

import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import 'set_version_planner.dart';

class SetVersionWriteResult {
  const SetVersionWriteResult({required this.filesWritten});
  final int filesWritten;
}

SetVersionWriteResult applySetVersionPlan(SetVersionPlan plan) {
  final pending = <_PendingWrite>[];

  for (final packagePlan in plan.packages) {
    if (!packagePlan.hasChanges) continue;
    final editor = YamlEditor(packagePlan.package.rawYaml);

    if (packagePlan.updateTopLevelVersion) {
      editor.update(['version'], packagePlan.newVersion);
    }
    for (final update in packagePlan.dependencyUpdates) {
      final path = <Object>[
        update.section.key,
        update.dependencyName,
        if (update.shape == HostedDeclarationShape.expanded) 'version',
      ];
      editor.update(path, update.newConstraint);
    }

    final contents = editor.toString();
    if (contents == packagePlan.package.rawYaml) continue;
    pending.add(
      _PendingWrite(
        path: packagePlan.package.pubspecPath,
        contents: contents,
      ),
    );
  }

  for (final write in pending) {
    File(write.path).writeAsStringSync(write.contents);
  }
  return SetVersionWriteResult(filesWritten: pending.length);
}

class _PendingWrite {
  const _PendingWrite({required this.path, required this.contents});
  final String path;
  final String contents;
}
