/// End-to-end orchestration of `club publish --auto`.
///
/// Reuses the prep pipeline from `prepare_engine.dart` to discover, plan,
/// and resolve version conflicts for every package in the closure, then
/// runs the existing [PublishRunner] for each package in topological order.
///
/// **Source files are never modified.** For every package with planned
/// dependency rewrites the runner passes the rewritten pubspec text
/// in-memory via [PublishOptions.pubspecOverride]. Validators see the
/// rewritten shape and the uploaded tarball ships the rewritten pubspec,
/// but the on-disk `pubspec.yaml` stays exactly as the user left it. This
/// keeps the workspace usable for local development between publish runs.
///
/// Topological order is important: by the time we publish package N every
/// package N transitively depends on is already on the server, so the
/// validator's `dart pub get` step can resolve N's hosted deps.
library;

import 'package:path/path.dart' as p;

import '../prepare/conflict_resolver.dart';
import '../prepare/prepare_engine.dart';
import '../prepare/pubspec_rewriter.dart';
import '../prepare/tarball_inspector.dart';
import '../prepare/tree_renderer.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import '../util/url.dart';
import 'publish_runner.dart';

class AutoPublishOptions {
  AutoPublishOptions({
    required this.directory,
    required this.targets,
    this.dryRun = false,
    this.force = false,
    this.skipValidation = false,
    this.ignoreWarnings = false,
    this.enhanced = false,
    this.serverFlag,
    this.onConflict = OnConflictMode.prompt,
    this.treeStyle = TreeStyle.stacked,
    this.showTree = true,
  });

  final String directory;
  final List<String> targets;
  final bool dryRun;
  final bool force;
  final bool skipValidation;
  final bool ignoreWarnings;
  final bool enhanced;
  final String? serverFlag;
  final OnConflictMode onConflict;

  /// Visual style for the dependency tree section. Defaults to
  /// [TreeStyle.stacked] — a publish-stack list with inline deps.
  final TreeStyle treeStyle;

  /// When false, the dependency tree section is suppressed (`--no-tree`).
  final bool showTree;
}

class AutoPublishRunner {
  AutoPublishRunner(this.options);
  final AutoPublishOptions options;

  Future<int> run() async {
    final PreparedWorkspace ws;
    try {
      ws = await prepareWorkspace(
        WorkspaceInputs(
          directory: options.directory,
          targets: options.targets,
          serverFlag: options.serverFlag,
          onConflict: options.onConflict,
          headerLabel: '🚀  ${bold('club publish --auto')}',
          dryRunLabel: options.dryRun,
        ),
      );
    } on PrepareEngineError catch (e) {
      return e.exitCode;
    }

    // ── Publish order ────────────────────────────────────────────────────
    final publishOrder = [
      for (final name in ws.order)
        if (ws.resolution.actions[name] != PackageAction.skip) name,
    ];
    if (publishOrder.isEmpty) {
      info('');
      success('Every package in the closure is marked skip. Nothing to do.');
      return ExitCodes.success;
    }

    // ── In-memory pubspec overrides ──────────────────────────────────────
    // For each plan with rewrites, build the rewritten pubspec.yaml
    // content and stash it keyed by package name. This map drives both the
    // tarball size pre-flight and the per-package PublishRunner call —
    // disk is never touched.
    final pubspecOverrides = <String, String>{
      for (final plan in ws.plans)
        if (plan.rewrites.isNotEmpty)
          plan.package.name: buildRewrittenYaml(plan)!,
    };
    final hasRewrites = pubspecOverrides.isNotEmpty;

    // ── Tarball sizes (pre-flight) ───────────────────────────────────────
    // Build each package's archive into a temp file using the in-memory
    // pubspec override, capture the compressed size, delete. Numbers
    // feed into the dependency tree so the user can spot oversized
    // packages before any upload happens.
    heading('Measuring tarballs');
    final inspectablePackages = [
      for (final name in publishOrder) ws.packages[name]!,
    ];
    final sizes = await measureTarballs(
      packages: inspectablePackages,
      pubspecOverrides: pubspecOverrides,
      onProgress: (name) => detail(gray('measuring $name…')),
    );
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
      heading('Tarball sizes');
      printTarballSizeTable(
        sizes,
        write: info,
        red: red,
        gray: gray,
        bold: bold,
      );
    }

    // ── Rewrite preview (same format as prepare) ─────────────────────────
    if (hasRewrites) {
      heading(
        options.dryRun
            ? 'Pubspec rewrites (in-memory, dry-run)'
            : 'Pubspec rewrites (in-memory — source files unchanged)',
      );
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
    }

    // ── Confirm ──────────────────────────────────────────────────────────
    if (!options.dryRun && !options.force && !isCI) {
      info('');
      try {
        final ok = await confirm(
          'Publish ${bold('${publishOrder.length}')} packages to '
          '${bold(displayServer(ws.server.url))}? '
          '${gray('(source pubspec.yaml files will not be modified)')}',
          defaultAnswer: false,
        );
        if (!ok) {
          info('Aborted.');
          return ExitCodes.config;
        }
      } on NonInteractiveError catch (e) {
        error(e.message);
        hint('Pass --force to skip this prompt.');
        return ExitCodes.config;
      }
    }

    // ── Dry-run bail ─────────────────────────────────────────────────────
    if (options.dryRun) {
      info('');
      box([
        bold('Dry-run complete'),
        gray('No packages were published. Source files were not touched.'),
        '${gray('Would publish')} ${publishOrder.length} '
            '${gray('packages with')} ${pubspecOverrides.length} '
            '${gray('in-memory pubspec rewrites')}',
      ]);
      return ExitCodes.success;
    }

    // ── Publish each package in topo order ───────────────────────────────
    // PublishRunner receives the override string (when present) and uses
    // it for both validation and the tarball — the on-disk pubspec is
    // never read. Pub workspace shadowing means `dart pub get` (run at
    // the workspace root by PublishRunner during validation) still
    // resolves locally from the unchanged source pubspec.
    final published = <String>[];
    for (var i = 0; i < publishOrder.length; i++) {
      final name = publishOrder[i];
      final pkg = ws.packages[name]!;
      final action = ws.resolution.actions[name] ?? PackageAction.publishNew;

      info('');
      heading('[${i + 1}/${publishOrder.length}] Publishing $name');

      final exitCode = await PublishRunner(
        PublishOptions(
          directory: pkg.directory,
          force: action == PackageAction.overwrite,
          skipValidation: options.skipValidation,
          ignoreWarnings: options.ignoreWarnings,
          enhanced: options.enhanced,
          serverFlag: ws.server.url,
          pubspecOverride: pubspecOverrides[name],
        ),
      ).run();

      if (exitCode != ExitCodes.success) {
        info('');
        error(
          'Publish of $name failed (exit code $exitCode). '
          'Aborting the chain.',
        );
        if (published.isNotEmpty) {
          hint(
            'Already published: ${published.join(', ')}. '
            'These remain on the server. Re-run after fixing $name to '
            'finish the rest.',
          );
        }
        return exitCode;
      }
      published.add(name);
    }

    // ── Summary ──────────────────────────────────────────────────────────
    info('');
    final overwriteCount = ws.resolution.actions.values
        .where((a) => a == PackageAction.overwrite)
        .length;
    final skipCount = ws.resolution.actions.values
        .where((a) => a == PackageAction.skip)
        .length;
    box([
      '🎉 ${bold('${published.length}')} packages published to '
          '${bold(displayServer(ws.server.url))}',
      ...[
        for (final n in published) '   ${green('✓')} $n',
      ],
      if (skipCount > 0) gray('Skipped: $skipCount (already published)'),
      if (overwriteCount > 0)
        gray('Force-pushed: $overwriteCount over existing version'),
    ]);
    return ExitCodes.success;
  }
}
