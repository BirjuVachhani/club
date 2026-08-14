/// Workspace-prep pipeline shared by `club prepare` and `club publish --auto`.
///
/// Runs the discover → target select → graph build → server resolve →
/// version-conflict-resolve → plan pipeline, with user-facing output for
/// each phase. Returns a [PreparedWorkspace] when everything resolves, or
/// throws [PrepareEngineError] (with the appropriate exit code) on failure
/// or user abort.
///
/// The runner that wraps the engine is responsible for rendering the final
/// dependency tree, the planned-rewrites table, the confirmation prompt,
/// and the actual rewrite/upload application.
library;

import 'dart:io';

import 'package:club_api/club_api.dart';
import 'package:path/path.dart' as p;

import '../publish/pubspec_reader.dart';
import '../publish/server_resolver.dart';
import '../util/exit_codes.dart';
import '../util/log.dart';
import '../util/prompt.dart';
import '../util/url.dart';
import 'conflict_resolver.dart';
import 'dependency_graph.dart';
import 'package_discovery.dart';
import 'rewrite_planner.dart';
import 'version_checker.dart';

/// Inputs to [prepareWorkspace]. Same shape across prepare and auto-publish.
class WorkspaceInputs {
  WorkspaceInputs({
    required this.directory,
    required this.targets,
    required this.onConflict,
    required this.headerLabel,
    this.serverFlag,
    this.dryRunLabel = false,
    this.versionSuffix,
    this.versionOverride,
  });

  /// Workspace root. Empty -> cwd.
  final String directory;

  /// Positional package names. When empty the engine shows an interactive
  /// multi-select picker.
  final List<String> targets;

  /// `--server` flag forwarded to [ServerResolver].
  final String? serverFlag;

  /// How to resolve version conflicts.
  final OnConflictMode onConflict;

  /// Header line shown at the top of the engine output, e.g.
  /// `🛠  club prepare` or `🚀  club publish --auto`.
  final String headerLabel;

  /// When true, the header is decorated with `(dry-run)` so the user
  /// knows the run will not touch disk.
  final bool dryRunLabel;

  /// Prerelease identifier applied to every discovered package's version,
  /// e.g. `pr2` for a pull request publish. Null for a normal run.
  final String? versionSuffix;

  /// One version to use for every discovered package, replacing whatever
  /// their pubspecs declare. Takes precedence over [versionSuffix].
  final String? versionOverride;
}

/// Snapshot of the workspace ready for the rewrite/publish phase.
class PreparedWorkspace {
  PreparedWorkspace({
    required this.rootDir,
    required this.packages,
    required this.graph,
    required this.targets,
    required this.order,
    required this.server,
    required this.resolution,
    required this.plans,
    required this.cycles,
  });

  final String rootDir;
  final Map<String, DiscoveredPackage> packages;
  final DependencyGraph graph;

  /// Target package names selected by the user (positional args or picker).
  final List<String> targets;

  /// Topological publish order — leaves first, dependents last.
  final List<String> order;

  /// Mutually-dependent package groups inside [order], in publish order.
  ///
  /// Empty for the common acyclic workspace. Members need their standalone
  /// resolution check deferred until the whole group is published — see
  /// `publish/cycle_verification.dart`.
  final List<List<String>> cycles;

  /// Every package in [order] that belongs to some group in [cycles].
  Set<String> get cycleMembers => {for (final g in cycles) ...g};

  final ResolvedServer server;
  final ConflictResolution resolution;
  final List<PackagePlan> plans;
}

/// Thrown by [prepareWorkspace] when the engine cannot continue. The
/// runner should propagate [exitCode] back to the OS.
class PrepareEngineError implements Exception {
  PrepareEngineError(this.exitCode);
  final int exitCode;
}

/// Runs the prep pipeline up to (and including) the rewrite plan.
///
/// User-facing output is emitted along the way; the caller is responsible
/// for everything from the dep-tree render onward.
Future<PreparedWorkspace> prepareWorkspace(WorkspaceInputs inputs) async {
  final rootDir = p.absolute(
    inputs.directory.isEmpty ? Directory.current.path : inputs.directory,
  );

  info('');
  info(
    '${inputs.headerLabel}'
    '${inputs.dryRunLabel ? gray(' (dry-run)') : ''}',
  );
  detail('root: $rootDir');

  // ── Discovery ────────────────────────────────────────────────────────────
  final Map<String, DiscoveredPackage> packages;
  try {
    packages = discoverPackages(
      rootDir,
      versionSuffix: inputs.versionSuffix,
      versionOverride: inputs.versionOverride,
    );
  } on FormatException catch (e) {
    error(e.message);
    throw PrepareEngineError(ExitCodes.data);
  }

  if (packages.isEmpty) {
    error('No publishable packages found under $rootDir.');
    hint(
      'A publishable package needs both `name` and `version` in its '
      'pubspec.yaml.',
    );
    throw PrepareEngineError(ExitCodes.noInput);
  }

  detail(
    'discovered ${bold('${packages.length}')} '
    '${packages.length == 1 ? 'package' : 'packages'}',
  );

  // ── Target selection ─────────────────────────────────────────────────────
  if (inputs.targets.isNotEmpty) {
    final unknown = [
      for (final name in inputs.targets)
        if (!packages.containsKey(name)) name,
    ];
    if (unknown.isNotEmpty) {
      error(
        'Unknown ${unknown.length == 1 ? 'package' : 'packages'}: '
        '${unknown.join(', ')}',
      );
      hint(
        'Discovered packages: '
        '${(packages.keys.toList()..sort()).join(', ')}',
      );
      throw PrepareEngineError(ExitCodes.data);
    }
  }

  final List<String> targets;
  try {
    targets = await _selectTargets(packages, inputs.targets);
  } on NonInteractiveError catch (e) {
    error(e.message);
    throw PrepareEngineError(ExitCodes.config);
  }
  if (targets.isEmpty) {
    info('Nothing selected. Aborting.');
    throw PrepareEngineError(ExitCodes.config);
  }

  // ── Graph + topo order ──────────────────────────────────────────────────
  final graph = buildDependencyGraph(packages);
  if (graph.errors.isNotEmpty) {
    for (final err in graph.errors) {
      error(err.message);
      if (err.hint != null) hint(err.hint!);
    }
    throw PrepareEngineError(ExitCodes.data);
  }

  final plan = planPublishOrder(graph, targets);
  final order = plan.order;

  // Cycles are published as a group rather than rejected, but the user should
  // know before confirming: within a group there is a window where the
  // first-uploaded member's dependencies are not yet resolvable.
  if (plan.hasCycles) {
    info('');
    warning(
      '${plan.cycles.length} dependency '
      '${plan.cycles.length == 1 ? 'cycle' : 'cycles'} in the closure:',
    );
    for (final group in plan.cycles) {
      detail(bold(describeCycle(group)));
    }
    hint(
      'Members publish as a group. The standalone resolution check is '
      'deferred until every member is up, then verified.',
    );
  }

  // ── Server resolution ───────────────────────────────────────────────────
  final firstTarget = packages[targets.first]!;
  final firstTargetPubspec = readPubspec(firstTarget.directory);
  final ResolvedServer server;
  try {
    server = await ServerResolver().resolve(
      serverFlag: inputs.serverFlag,
      pubspec: firstTargetPubspec,
    );
  } on ServerResolutionError catch (e) {
    error(e.message);
    if (e.hint != null) hint(e.hint!);
    throw PrepareEngineError(ExitCodes.config);
  } on NonInteractiveError catch (e) {
    error(e.message);
    throw PrepareEngineError(ExitCodes.config);
  }
  detail(
    'server: ${bold(displayServer(server.url))} '
    '${gray("(${describeServerSource(server.source)})")}',
  );

  // ── Version conflict check ──────────────────────────────────────────────
  final client = ClubClient(
    serverUrl: Uri.parse(server.url),
    token: server.token,
  );
  final ConflictResolution resolution;
  try {
    final conflicts = await findVersionConflicts(
      client: client,
      packages: packages,
      order: order,
      serverUrl: server.url,
    );
    resolution = await resolveConflicts(
      order: order,
      conflicts: conflicts,
      mode: inputs.onConflict,
    );
  } on NonInteractiveError catch (e) {
    error(e.message);
    throw PrepareEngineError(ExitCodes.config);
  } finally {
    client.close();
  }
  if (resolution.aborted) {
    info('');
    info('Aborted.');
    throw PrepareEngineError(ExitCodes.config);
  }

  // ── Planning ────────────────────────────────────────────────────────────
  final List<PackagePlan> plans;
  try {
    plans = planRewrites(
      graph: graph,
      order: order,
      serverUrl: server.url,
      actions: resolution.actions,
    );
  } on MissingVersionError catch (e) {
    error(e.toString());
    hint(
      'Add a `version:` field to ${e.packageNames.length == 1 ? "that "
          "package's" : "each of those packages'"} pubspec.yaml before '
      'preparing dependents.',
    );
    throw PrepareEngineError(ExitCodes.data);
  }

  return PreparedWorkspace(
    rootDir: rootDir,
    packages: packages,
    graph: graph,
    targets: targets,
    order: order,
    server: server,
    resolution: resolution,
    plans: plans,
    cycles: plan.cycles,
  );
}

Future<List<String>> _selectTargets(
  Map<String, DiscoveredPackage> packages,
  List<String> positionalTargets,
) async {
  if (positionalTargets.isNotEmpty) {
    return [
      for (final n in {...positionalTargets}) n,
    ];
  }

  info('');
  final sortedNames = packages.keys.toList()..sort();
  return pickMulti<String>(
    'Select packages to prepare:',
    [
      for (final name in sortedNames)
        PickOption(
          label: name,
          value: name,
          detail: packages[name]!.version ?? '(no version)',
        ),
    ],
  );
}

/// Human-readable label for the original dependency declaration shape.
/// Used by both runners in their planned-rewrites preview.
String shapeLabel(DeclarationShape s) {
  switch (s) {
    case DeclarationShape.pathDependency:
      return 'path';
    case DeclarationShape.hostedByName:
      return 'hosted-by-name';
    case DeclarationShape.explicitHosted:
      return 'hosted';
  }
}
