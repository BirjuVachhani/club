/// End-to-end orchestration of `club prepare`.
///
/// Delegates discovery → planning to [prepareWorkspace] in `prepare_engine.dart`
/// (shared with `club publish --auto`). This runner owns the rewrite-only
/// phase: tree render, planned-rewrites preview, confirm prompt, write.
library;

import 'package:path/path.dart' as p;

import '../util/exit_codes.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import 'conflict_resolver.dart';
import 'prepare_engine.dart';
import 'pubspec_rewriter.dart';
import 'tarball_inspector.dart';
import 'tree_renderer.dart';

export '../util/exit_codes.dart' show ExitCodes;

/// Options consumed by [PrepareRunner.run].
class PrepareOptions {
  PrepareOptions({
    required this.directory,
    required this.targets,
    this.dryRun = false,
    this.force = false,
    this.serverFlag,
    this.onConflict = OnConflictMode.prompt,
    this.treeStyle = TreeStyle.stacked,
    this.showTree = true,
  });

  /// Root directory to discover packages from. Empty -> cwd.
  final String directory;

  /// Package names supplied as positional args. When empty, the runner
  /// shows an interactive multi-select picker.
  final List<String> targets;

  final bool dryRun;
  final bool force;
  final String? serverFlag;

  /// How to resolve packages whose local version is already published.
  /// Defaults to per-conflict interactive prompt.
  final OnConflictMode onConflict;

  /// Visual style for the dependency tree section. Defaults to
  /// [TreeStyle.stacked] — a publish-stack list with inline deps.
  final TreeStyle treeStyle;

  /// When false, the dependency tree section is suppressed entirely
  /// (controlled via `--no-tree`).
  final bool showTree;
}

class PrepareRunner {
  PrepareRunner(this.options);

  final PrepareOptions options;

  Future<int> run() async {
    final PreparedWorkspace ws;
    try {
      ws = await prepareWorkspace(
        WorkspaceInputs(
          directory: options.directory,
          targets: options.targets,
          serverFlag: options.serverFlag,
          onConflict: options.onConflict,
          headerLabel: '🛠  ${bold('club prepare')}',
          dryRunLabel: options.dryRun,
        ),
      );
    } on PrepareEngineError catch (e) {
      return e.exitCode;
    }

    final totalRewrites =
        ws.plans.fold<int>(0, (s, plan) => s + plan.rewrites.length);
    final modifiedCount = ws.plans.where((p) => p.rewrites.isNotEmpty).length;

    // ── Tarball sizes (pre-flight) ───────────────────────────────────────
    // Measure first so the dependency tree can show per-package sizes
    // inline. Skip-marked packages aren't measured (they won't publish).
    final inspectablePackages = [
      for (final plan in ws.plans)
        if (ws.resolution.actions[plan.package.name] != PackageAction.skip)
          plan.package,
    ];
    final List<TarballSize> sizes;
    if (inspectablePackages.isNotEmpty) {
      heading('Measuring tarballs');
      sizes = await measureTarballs(
        packages: inspectablePackages,
        onProgress: (name) => detail(gray('measuring $name…')),
      );
    } else {
      sizes = const [];
    }
    final sizeMap = {for (final s in sizes) s.packageName: s};

    // ── Dependency tree ──────────────────────────────────────────────────
    if (options.showTree) {
      heading(
        options.treeStyle == TreeStyle.stacked
            ? 'Publish stack (top-to-bottom)'
            : 'Dependency tree',
      );
      renderDependencyTree(
        graph: ws.graph,
        order: ws.order,
        selectedTargets: ws.targets.toSet(),
        style: options.treeStyle,
        actions: ws.resolution.actions,
        sizes: sizeMap,
      );
      if (sizes.isNotEmpty) {
        final totalBytes = sizes.fold<int>(0, (sum, s) => sum + s.bytes);
        final totalFiles = sizes.fold<int>(0, (sum, s) => sum + s.fileCount);
        info('');
        info(
          '   ${gray('Total:')} ${bold('${sizes.length}')} '
          '${sizes.length == 1 ? 'package' : 'packages'} '
          '${gray('·')} ${bold('$totalFiles')} files '
          '${gray('·')} ${bold(formatBytes(totalBytes))}',
        );
      }
    } else if (sizes.isNotEmpty) {
      // `--no-tree` fallback: still surface size info via the standalone
      // table so size pre-flight is never silent.
      heading('Tarball sizes');
      printTarballSizeTable(
        sizes,
        write: info,
        red: red,
        gray: gray,
        bold: bold,
      );
    }

    if (totalRewrites == 0) {
      info('');
      success('Nothing to rewrite — no internal dependencies in the closure.');
      return ExitCodes.success;
    }

    // ── Planned rewrites ─────────────────────────────────────────────────
    heading(options.dryRun ? 'Planned rewrites (dry-run)' : 'Planned rewrites');
    final widestDepName = ws.plans
        .expand((plan) => plan.rewrites)
        .map((r) => r.depName.length)
        .fold<int>(0, (m, l) => l > m ? l : m);
    for (final plan in ws.plans) {
      if (plan.rewrites.isEmpty) continue;
      final relPath = p.relative(
        p.join(plan.package.directory, 'pubspec.yaml'),
        from: ws.rootDir,
      );
      info('   ${bold(plan.package.name)} ${gray('— $relPath')}');
      for (final r in plan.rewrites) {
        final paddedName = r.depName.padRight(widestDepName);
        final shape = gray('(${shapeLabel(r.declaredAs)})');
        info(
          '      ${gray(r.section.key)}.$paddedName  $shape  →  '
          '${cyan('hosted')} ${cyan(r.constraint)}',
        );
      }
    }

    // ── Confirm ──────────────────────────────────────────────────────────
    if (!options.dryRun && !options.force && !isCI) {
      info('');
      try {
        final ok = await confirm(
          'Apply ${bold('$totalRewrites')} dep rewrites to '
          '${bold('$modifiedCount')} pubspec.yaml '
          '${modifiedCount == 1 ? 'file' : 'files'}?',
          defaultAnswer: true,
        );
        if (!ok) {
          info('Aborted.');
          return ExitCodes.config;
        }
      } on NonInteractiveError catch (e) {
        error(e.message);
        hint(
          'Pass --force to skip this prompt, or pass package names as '
          'positional arguments.',
        );
        return ExitCodes.config;
      }
    }

    // ── Apply ────────────────────────────────────────────────────────────
    applyPlans(ws.plans, dryRun: options.dryRun);

    info('');
    final overwriteCount = ws.resolution.actions.values
        .where((a) => a == PackageAction.overwrite)
        .length;
    final skipCount = ws.resolution.actions.values
        .where((a) => a == PackageAction.skip)
        .length;
    final conflictSummary = (overwriteCount + skipCount) == 0
        ? null
        : [
            if (overwriteCount > 0) '$overwriteCount to overwrite',
            if (skipCount > 0) '$skipCount to skip',
          ].join(', ');
    if (options.dryRun) {
      box([
        bold('Dry-run complete'),
        gray('No files were modified.'),
        '${gray('Would rewrite')} $totalRewrites '
            '${gray('deps across')} $modifiedCount '
            '${gray(modifiedCount == 1 ? 'pubspec.yaml file' : 'pubspec.yaml files')}',
        if (conflictSummary != null) gray('Conflicts: $conflictSummary'),
      ]);
    } else {
      success(
        'Prepared $modifiedCount '
        '${modifiedCount == 1 ? 'pubspec.yaml file' : 'pubspec.yaml files'} '
        '($totalRewrites dep ${totalRewrites == 1 ? 'rewrite' : 'rewrites'}).',
      );
      if (conflictSummary != null) {
        detail(gray('Conflict resolution: $conflictSummary.'));
      }
    }
    return ExitCodes.success;
  }
}
