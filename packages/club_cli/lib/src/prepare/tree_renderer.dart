/// Console renderings of the publish-order subgraph.
///
/// Two styles are available — chosen via [TreeStyle]:
///
///   * [TreeStyle.nested]: traditional indented tree with `├──` / `└──`
///     branches. Familiar and compact for narrow terminals; subsequent
///     occurrences of a multi-parent node fall back to `↑ shown above`.
///
///   * [TreeStyle.stacked] (default): a "publish stack" — flat list in
///     publish order where every package shows its order number, status,
///     size, and inline `depends on ↑` / `depended on by →` lines. Reads
///     like a stack trace, every node appears exactly once.
library;

import '../util/log.dart';
import 'conflict_resolver.dart';
import 'dependency_graph.dart';
import 'tarball_inspector.dart';

/// Visual style for [renderDependencyTree].
enum TreeStyle {
  /// Indented `├──` / `└──` tree (legacy behaviour).
  nested,

  /// Publish stack — flat list in publish order with inline deps.
  stacked,
}

/// Parse a `--tree` option value into a [TreeStyle]. Returns `null` for
/// unknown strings so the command layer can surface a usage error.
TreeStyle? parseTreeStyle(String? raw) {
  switch (raw?.toLowerCase()) {
    case 'nested':
      return TreeStyle.nested;
    case 'stacked':
      return TreeStyle.stacked;
  }
  return null;
}

/// Print the dependency tree in the requested [style].
///
/// [order] is the topological publish order — leaves first, dependents
/// last. [sizes] is keyed by package name; when present the tree shows
/// the compressed tarball size next to each node. [actions] supplies the
/// per-package status badge.
void renderDependencyTree({
  required DependencyGraph graph,
  required List<String> order,
  required Set<String> selectedTargets,
  required TreeStyle style,
  Map<String, PackageAction> actions = const {},
  Map<String, TarballSize> sizes = const {},
}) {
  switch (style) {
    case TreeStyle.nested:
      _renderNested(
        graph: graph,
        order: order,
        selectedTargets: selectedTargets,
        actions: actions,
        sizes: sizes,
      );
    case TreeStyle.stacked:
      _renderStacked(
        graph: graph,
        order: order,
        selectedTargets: selectedTargets,
        actions: actions,
        sizes: sizes,
      );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Stacked style — Publish stack (default)
// ─────────────────────────────────────────────────────────────────────────

void _renderStacked({
  required DependencyGraph graph,
  required List<String> order,
  required Set<String> selectedTargets,
  required Map<String, PackageAction> actions,
  required Map<String, TarballSize> sizes,
}) {
  final inOrder = order.toSet();

  // Reverse adjacency: for each package, who in the closure depends on it.
  final dependedOnBy = <String, List<String>>{};
  for (final from in order) {
    for (final edge in graph.outgoing(from)) {
      if (!inOrder.contains(edge.to)) continue;
      dependedOnBy.putIfAbsent(edge.to, () => []).add(from);
    }
  }
  for (final list in dependedOnBy.values) {
    list.sort();
  }

  // Pre-compute column widths so the order/name/version/status columns
  // line up.
  final widestNumber = '[${order.length}]'.length;
  final widestName = order
      .map((n) => n.length + (selectedTargets.contains(n) ? 9 : 0))
      .fold<int>(0, (m, l) => l > m ? l : m);
  final widestVersion = order
      .map((n) => (graph.packages[n]!.version ?? '?').length)
      .fold<int>(0, (m, l) => l > m ? l : m);
  final widestStatus = _allActionLabels()
      .map((s) => s.length)
      .fold<int>(0, (m, l) => l > m ? l : m);

  for (var i = 0; i < order.length; i++) {
    final name = order[i];
    final pkg = graph.packages[name]!;
    final action = actions[name] ?? PackageAction.publishNew;

    final number = '[${i + 1}]'.padLeft(widestNumber);
    final isTarget = selectedTargets.contains(name);
    final nameWithTarget = isTarget ? '$name ${gray('◀ target')}' : name;
    // Pad against the visible-length cap so `◀ target` is included.
    final visibleNameLen = name.length + (isTarget ? 9 : 0);
    final paddedName =
        nameWithTarget + ' ' * (widestName - visibleNameLen);

    final version =
        cyan((pkg.version ?? '?').padRight(widestVersion));
    final status = _renderActionLabel(action).padRight(widestStatus);
    final sizeStr = sizes.containsKey(name)
        ? gray('· ${formatBytes(sizes[name]!.bytes)}')
        : '';

    info('  ${cyan('▶')} $number $paddedName  $version  $status  $sizeStr');

    final depsLine = _formatDependsOn(graph, name, inOrder);
    if (depsLine != null) {
      info('       ${gray('depends on')}      ${gray('↑')} $depsLine');
    }
    final reverseDeps = dependedOnBy[name];
    if (reverseDeps != null && reverseDeps.isNotEmpty) {
      info(
        '       ${gray('depended on by')}  ${gray('→')} '
        '${reverseDeps.join(', ')}',
      );
    }
    if (i < order.length - 1) info('');
  }
}

/// Build the "depends on ↑ X ^1.0.0, Y ^2.0.0" suffix for [name].
/// Returns null when the package has no internal deps in the closure.
String? _formatDependsOn(
  DependencyGraph graph,
  String name,
  Set<String> inOrder,
) {
  final entries = <String>[];
  for (final edge in graph.outgoing(name)) {
    if (!inOrder.contains(edge.to)) continue;
    final target = graph.packages[edge.to]!;
    final version = target.version;
    final constraint = version != null ? '^$version' : '?';
    entries.add('${edge.to} $constraint');
  }
  if (entries.isEmpty) return null;
  entries.sort();
  return entries.join(', ');
}

String _renderActionLabel(PackageAction action) {
  switch (action) {
    case PackageAction.publishNew:
      return green('✓ publish');
    case PackageAction.overwrite:
      return yellow('⚠ overwrite');
    case PackageAction.skip:
      return gray('— skip');
  }
}

List<String> _allActionLabels() => [
      '✓ publish',
      '⚠ overwrite',
      '— skip',
    ];

// ─────────────────────────────────────────────────────────────────────────
// Nested style — indented tree (legacy)
// ─────────────────────────────────────────────────────────────────────────

void _renderNested({
  required DependencyGraph graph,
  required List<String> order,
  required Set<String> selectedTargets,
  required Map<String, PackageAction> actions,
  required Map<String, TarballSize> sizes,
}) {
  final inOrder = order.toSet();

  // reverse[name] = packages that depend on `name` (limited to closure).
  final reverse = <String, List<String>>{};
  for (final from in order) {
    for (final edge in graph.outgoing(from)) {
      if (!inOrder.contains(edge.to)) continue;
      reverse.putIfAbsent(edge.to, () => []).add(from);
    }
  }
  for (final list in reverse.values) {
    list.sort();
  }

  // Roots = packages with no outgoing edges into the closure.
  final roots = [
    for (final n in order)
      if (graph.outgoing(n).every((e) => !inOrder.contains(e.to))) n,
  ]..sort();

  final orderIndex = {for (var i = 0; i < order.length; i++) order[i]: i + 1};
  final rendered = <String>{};

  for (final r in roots) {
    _renderNestedNode(
      r,
      reverse: reverse,
      graph: graph,
      selectedTargets: selectedTargets,
      actions: actions,
      sizes: sizes,
      orderIndex: orderIndex,
      rendered: rendered,
      prefix: '',
      isLast: true,
      isRoot: true,
    );
  }
}

void _renderNestedNode(
  String name, {
  required Map<String, List<String>> reverse,
  required DependencyGraph graph,
  required Set<String> selectedTargets,
  required Map<String, PackageAction> actions,
  required Map<String, TarballSize> sizes,
  required Map<String, int> orderIndex,
  required Set<String> rendered,
  required String prefix,
  required bool isLast,
  required bool isRoot,
}) {
  final pkg = graph.packages[name]!;
  final number = '[${orderIndex[name]}]';
  final marker = isRoot ? cyan('● ') : (isLast ? '└── ' : '├── ');
  final version = cyan(pkg.version ?? '?');
  final marked = selectedTargets.contains(name) ? gray(' ◀ target') : '';
  final action = actions[name] ?? PackageAction.publishNew;
  final status = _renderActionLabel(action);
  final sizeStr = sizes.containsKey(name)
      ? gray('  · ${formatBytes(sizes[name]!.bytes)}')
      : '';
  final alreadyShown = !rendered.add(name);

  final body =
      '$number ${selectedTargets.contains(name) ? bold(name) : name} '
      '$version$marked   $status$sizeStr';
  final line = isRoot
      ? '   $marker$body'
      : '   $prefix${gray(marker)}$body${alreadyShown ? gray('   ↑ shown above') : ''}';
  info(line);

  if (alreadyShown) return; // Don't recurse into a node we've already drawn.

  final children = reverse[name] ?? const <String>[];
  for (var i = 0; i < children.length; i++) {
    final childIsLast = i == children.length - 1;
    final childPrefix = isRoot
        ? '    '
        : '$prefix${isLast ? '    ' : '│   '}';
    _renderNestedNode(
      children[i],
      reverse: reverse,
      graph: graph,
      selectedTargets: selectedTargets,
      actions: actions,
      sizes: sizes,
      orderIndex: orderIndex,
      rendered: rendered,
      prefix: childPrefix,
      isLast: childIsLast,
      isRoot: false,
    );
  }
}
