/// Resolves version conflicts surfaced by [findVersionConflicts] into a
/// per-package [PackageAction].
///
/// Either honors a global [OnConflictMode] passed via `--on-conflict`, or —
/// when the mode is [OnConflictMode.prompt] — asks the user once per
/// conflict via a single-select arrow-key picker. Choosing "Abort" anywhere
/// in the run aborts the whole prepare.
library;

import '../util/log.dart';
import '../util/prompt.dart';
import 'version_checker.dart';

/// What we plan to do with a single package during prepare/publish.
enum PackageAction {
  /// No published version of this name+version yet — fresh publish.
  publishNew,

  /// Version already published. User opted to force-push over it. The
  /// package's pubspec is rewritten as if it were a fresh publish; the
  /// `force` flag is later passed to the upload itself.
  overwrite,

  /// Version already published. User opted to reuse it as-is. The
  /// package's pubspec is left untouched, but every dependent still
  /// references its (already-published) version.
  skip,
}

/// How `--on-conflict` should resolve every conflict in the run.
enum OnConflictMode {
  /// Per-conflict interactive picker (only valid when stdin is a tty).
  prompt,

  /// Force-publish every conflict.
  overwrite,

  /// Reuse the already-published version for every conflict.
  skip,

  /// Abort the run if any conflict is detected.
  abort,
}

/// Parse a `--on-conflict` value. Returns null for unknown values so the
/// command layer can surface a usage error.
OnConflictMode? parseOnConflictMode(String? raw) {
  if (raw == null) return null;
  switch (raw.toLowerCase()) {
    case 'overwrite':
      return OnConflictMode.overwrite;
    case 'skip':
      return OnConflictMode.skip;
    case 'abort':
      return OnConflictMode.abort;
    case 'prompt':
      return OnConflictMode.prompt;
  }
  return null;
}

/// Outcome of [resolveConflicts]: per-package action map plus an `aborted`
/// flag so the caller can short-circuit cleanly.
class ConflictResolution {
  ConflictResolution({required this.actions, required this.aborted});
  final Map<String, PackageAction> actions;
  final bool aborted;

  bool get hasOverwrites =>
      actions.values.any((a) => a == PackageAction.overwrite);
  bool get hasSkips => actions.values.any((a) => a == PackageAction.skip);
  int get newCount =>
      actions.values.where((a) => a == PackageAction.publishNew).length;
}

/// Build the action map for every package in [order].
///
/// Packages without a conflict default to [PackageAction.publishNew].
/// Conflicts get resolved according to [mode].
Future<ConflictResolution> resolveConflicts({
  required List<String> order,
  required List<VersionConflict> conflicts,
  required OnConflictMode mode,
}) async {
  final actions = <String, PackageAction>{
    for (final name in order) name: PackageAction.publishNew,
  };

  if (conflicts.isEmpty) {
    return ConflictResolution(actions: actions, aborted: false);
  }

  // --on-conflict abort: bail before applying any resolution.
  if (mode == OnConflictMode.abort) {
    return ConflictResolution(actions: actions, aborted: true);
  }

  // Bulk modes apply uniformly.
  if (mode == OnConflictMode.overwrite || mode == OnConflictMode.skip) {
    final action = mode == OnConflictMode.overwrite
        ? PackageAction.overwrite
        : PackageAction.skip;
    for (final c in conflicts) {
      actions[c.packageName] = action;
    }
    return ConflictResolution(actions: actions, aborted: false);
  }

  // Interactive prompt.
  if (!isInteractive) {
    throw NonInteractiveError(
      'Version conflicts detected but stdin is non-interactive. '
      'Pass --on-conflict <overwrite|skip|abort> to resolve them.',
    );
  }

  for (final conflict in conflicts) {
    info('');
    final choice = await pick<_Choice>(
      '${bold(conflict.packageName)} ${cyan(conflict.localVersion)} '
      'is already published to ${conflict.serverUrl}.',
      [
        PickOption(
          label: 'Overwrite',
          value: _Choice.overwrite,
          detail: 'force-push, replacing the existing version',
        ),
        PickOption(
          label: 'Skip',
          value: _Choice.skip,
          detail: 'leave the existing version in place',
        ),
        PickOption(
          label: 'Abort',
          value: _Choice.abort,
          detail: 'cancel the run',
        ),
      ],
    );
    if (choice == _Choice.abort) {
      return ConflictResolution(actions: actions, aborted: true);
    }
    actions[conflict.packageName] = choice == _Choice.overwrite
        ? PackageAction.overwrite
        : PackageAction.skip;
  }

  return ConflictResolution(actions: actions, aborted: false);
}

enum _Choice { overwrite, skip, abort }
