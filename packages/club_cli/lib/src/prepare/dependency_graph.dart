/// Dependency graph over discovered packages.
///
/// Edges represent "package A depends on package B" — i.e. B is referenced
/// from A's `dependencies` or `dev_dependencies`. A dep counts as internal
/// when its name matches another discovered package, regardless of whether it
/// is declared as a `path:` or hosted-by-name (pub workspace shadowing).
///
/// External `path:` deps (paths to directories that are not part of the
/// discovered set) are surfaced as [GraphError]s so the publish flow can
/// abort instead of silently leaving them unrewritten.
library;

import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';

import 'package_discovery.dart';

/// Which pubspec section a dep lives in. We only graph the two sections
/// that ship in the published pubspec.
enum DepSection {
  dependencies('dependencies'),
  devDependencies('dev_dependencies');

  const DepSection(this.key);
  final String key;
}

/// One edge in the graph: package [from] depends on package [to] via [section].
class DependencyEdge {
  DependencyEdge({
    required this.from,
    required this.to,
    required this.section,
    required this.declaredAs,
  });

  /// Name of the depending package.
  final String from;

  /// Name of the depended-on package.
  final String to;
  final DepSection section;

  /// How the dep was declared in the pubspec — informational, used for
  /// rendering and to know whether a path-rewrite is required.
  final DeclarationShape declaredAs;
}

/// Shape of the original dep declaration. Both shapes get rewritten to
/// hosted, but knowing the original lets us produce useful diagnostics.
enum DeclarationShape {
  /// `pkg: ^1.2.3` or `pkg: any` — relies on workspace shadowing.
  hostedByName,

  /// `pkg: { path: ../pkg }` — explicit local path dependency.
  pathDependency,

  /// `pkg: { hosted: <url>, version: ... }` — already explicit-hosted.
  /// May or may not point at our target server; we still rewrite it so the
  /// URL and version constraint match the expected publish target.
  explicitHosted,
}

/// The full graph + any errors found while building it.
class DependencyGraph {
  DependencyGraph._({
    required this.packages,
    required this.edges,
    required this.errors,
    required Map<String, List<DependencyEdge>> adjacency,
  }) : _adjacency = adjacency;

  /// Construct from a flat edge list. Pre-indexes outgoing edges by package
  /// name so [outgoing] is O(1) regardless of graph size.
  factory DependencyGraph({
    required Map<String, DiscoveredPackage> packages,
    required List<DependencyEdge> edges,
    required List<GraphError> errors,
  }) {
    final adjacency = <String, List<DependencyEdge>>{};
    for (final e in edges) {
      adjacency.putIfAbsent(e.from, () => []).add(e);
    }
    return DependencyGraph._(
      packages: packages,
      edges: edges,
      errors: errors,
      adjacency: adjacency,
    );
  }

  /// All discovered packages, keyed by name.
  final Map<String, DiscoveredPackage> packages;

  /// All edges across the graph.
  final List<DependencyEdge> edges;

  /// Construction-time errors (external path deps, etc).
  final List<GraphError> errors;

  final Map<String, List<DependencyEdge>> _adjacency;

  /// Outgoing edges from [packageName]. Empty list when [packageName] is a
  /// leaf or unknown.
  List<DependencyEdge> outgoing(String packageName) =>
      _adjacency[packageName] ?? const [];
}

/// A construction-time error: usually a path dep pointing outside the
/// discovered set.
class GraphError {
  GraphError(this.message, {this.hint});
  final String message;
  final String? hint;
}

/// Build a [DependencyGraph] from a discovered package set.
DependencyGraph buildDependencyGraph(Map<String, DiscoveredPackage> packages) {
  final edges = <DependencyEdge>[];
  final errors = <GraphError>[];

  // Index from canonical directory path back to a package name, so a
  // `path:` dep can be resolved even when its key in pubspec doesn't match
  // the actual package's name (rare but legal).
  final byDir = <String, String>{
    for (final entry in packages.entries) entry.value.directory: entry.key,
  };

  for (final pkg in packages.values) {
    _scanSection(
      pkg: pkg,
      section: DepSection.dependencies,
      deps: pkg.pubspec.dependencies,
      packages: packages,
      byDir: byDir,
      edges: edges,
      errors: errors,
    );
    _scanSection(
      pkg: pkg,
      section: DepSection.devDependencies,
      deps: pkg.pubspec.devDependencies,
      packages: packages,
      byDir: byDir,
      edges: edges,
      errors: errors,
    );
  }

  return DependencyGraph(
    packages: packages,
    edges: edges,
    errors: errors,
  );
}

void _scanSection({
  required DiscoveredPackage pkg,
  required DepSection section,
  required Map<String, Dependency> deps,
  required Map<String, DiscoveredPackage> packages,
  required Map<String, String> byDir,
  required List<DependencyEdge> edges,
  required List<GraphError> errors,
}) {
  for (final entry in deps.entries) {
    final depName = entry.key;
    final dep = entry.value;

    if (dep is PathDependency) {
      // Resolve the path against the depending package's directory and
      // see whether it lands inside any discovered package.
      final absolute = p.canonicalize(p.normalize(p.join(pkg.directory, dep.path)));
      final matchedName = byDir[absolute];
      if (matchedName == null) {
        errors.add(
          GraphError(
            '${pkg.name}: ${section.key}.$depName is a path dependency '
            'pointing outside the workspace (${dep.path}).',
            hint:
                'Move the target package into the workspace or replace the '
                'dependency with a hosted reference before publishing.',
          ),
        );
        continue;
      }
      edges.add(
        DependencyEdge(
          from: pkg.name,
          to: matchedName,
          section: section,
          declaredAs: DeclarationShape.pathDependency,
        ),
      );
      continue;
    }

    if (dep is HostedDependency) {
      // Workspace shadowing: a hosted-by-name dep counts as internal when
      // its name matches another discovered package.
      if (packages.containsKey(depName)) {
        final shape = dep.hosted == null
            ? DeclarationShape.hostedByName
            : DeclarationShape.explicitHosted;
        edges.add(
          DependencyEdge(
            from: pkg.name,
            to: depName,
            section: section,
            declaredAs: shape,
          ),
        );
      }
      // Else: a regular external hosted dep — not our concern.
      continue;
    }

    // SdkDependency / GitDependency / unknown shapes — leave alone. The
    // existing publish-time validators will flag them if they're problems.
  }
}

/// Compute the publish-order closure starting from [targets].
///
/// Returns the topologically ordered list of package names that must be
/// published (or rewritten) before the targets. The list is ordered with
/// dependencies first, dependents last — i.e. you can iterate it and publish
/// in order.
///
/// Throws [CycleError] if a cycle is reachable from the targets.
List<String> publishOrder(DependencyGraph graph, List<String> targets) {
  final reachable = <String>{};

  // 1. Discover every package reachable from the targets via outgoing edges.
  void visit(String name) {
    if (!reachable.add(name)) return;
    for (final e in graph.outgoing(name)) {
      visit(e.to);
    }
  }

  for (final t in targets) {
    visit(t);
  }

  // 2. Topo-sort the reachable subgraph using DFS post-order, with a
  // path-stack to detect cycles.
  final order = <String>[];
  final state = <String, _Mark>{};
  final stack = <String>[];

  void dfs(String name) {
    final mark = state[name];
    if (mark == _Mark.done) return;
    if (mark == _Mark.active) {
      final cycleStart = stack.indexOf(name);
      throw CycleError(stack.sublist(cycleStart) + [name]);
    }
    state[name] = _Mark.active;
    stack.add(name);
    for (final e in graph.outgoing(name)) {
      if (reachable.contains(e.to)) dfs(e.to);
    }
    stack.removeLast();
    state[name] = _Mark.done;
    order.add(name);
  }

  for (final t in targets) {
    dfs(t);
  }

  // Append any remaining reachable nodes that weren't picked up via the
  // target DFS (defensive — shouldn't happen given step 1, but cheap).
  for (final n in reachable) {
    if (state[n] != _Mark.done) dfs(n);
  }

  return order;
}

enum _Mark { active, done }

/// Raised when [publishOrder] detects a cycle. The [path] is the back-edge
/// trace, including the repeated node at both ends.
class CycleError implements Exception {
  CycleError(this.path);
  final List<String> path;
  @override
  String toString() => 'Dependency cycle: ${path.join(' -> ')}';
}
