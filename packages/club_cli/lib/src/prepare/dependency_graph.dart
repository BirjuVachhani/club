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
///
/// The graph is allowed to contain cycles. Mutual dependencies between
/// packages are legal on pub.dev and do occur in real monorepos, so
/// [planPublishOrder] groups them into strongly-connected components rather
/// than rejecting the workspace. Only a self-dependency is a hard error.
library;

import 'dart:math';

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
  /// Records an edge to [to], rejecting self-references.
  ///
  /// A package that depends on itself cannot be published under any ordering:
  /// the constraint would have to be satisfied by the very version being
  /// uploaded. Unlike a cycle between distinct packages (which publishes as a
  /// group), there is no second upload that can close the loop.
  void addEdge(String depName, String to, DeclarationShape shape) {
    if (to == pkg.name) {
      errors.add(
        GraphError(
          '${pkg.name}: ${section.key}.$depName makes the package depend on '
          'itself.',
          hint:
              'A self-dependency can never resolve, because the constraint '
              'would have to be satisfied by the version being published. '
              'Remove the entry.',
        ),
      );
      return;
    }
    edges.add(
      DependencyEdge(
        from: pkg.name,
        to: to,
        section: section,
        declaredAs: shape,
      ),
    );
  }

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
      addEdge(depName, matchedName, DeclarationShape.pathDependency);
      continue;
    }

    if (dep is HostedDependency) {
      // Workspace shadowing: a hosted-by-name dep counts as internal when
      // its name matches another discovered package.
      if (packages.containsKey(depName)) {
        addEdge(
          depName,
          depName,
          dep.hosted == null
              ? DeclarationShape.hostedByName
              : DeclarationShape.explicitHosted,
        );
      }
      // Else: a regular external hosted dep — not our concern.
      continue;
    }

    // SdkDependency / GitDependency / unknown shapes — leave alone. The
    // existing publish-time validators will flag them if they're problems.
  }
}

/// The ordered publish closure for a set of targets, plus any cycle groups
/// found inside it.
class PublishPlan {
  PublishPlan({required this.order, required this.cycles});

  /// Topological publish order — dependencies first, dependents last. Iterate
  /// it and publish in sequence.
  ///
  /// Packages inside a cycle group are adjacent in this list, but no ordering
  /// among them can satisfy their constraints: see [cycles].
  final List<String> order;

  /// Groups of packages that mutually depend on each other, in publish order.
  ///
  /// Each group is a strongly-connected component with more than one member.
  /// Every name here also appears in [order]. A group has to be published as a
  /// unit: whichever member goes first names a sibling version that is not on
  /// the server yet, so its standalone resolution only succeeds once the whole
  /// group has landed.
  final List<List<String>> cycles;

  late final Map<String, List<String>> _byMember = {
    for (final group in cycles)
      for (final name in group) name: group,
  };

  /// The cycle group containing [name], or null when [name] publishes alone.
  List<String>? cycleFor(String name) => _byMember[name];

  /// Every package that belongs to some cycle group.
  Set<String> get cycleMembers => _byMember.keys.toSet();

  bool get hasCycles => cycles.isNotEmpty;
}

/// Compute the publish-order closure starting from [targets].
///
/// Cycles are grouped rather than rejected. A mutual dependency between two
/// packages is legal on pub.dev (and common: `firebase_ui_auth` and
/// `firebase_ui_oauth` depend on each other in released versions), so club
/// publishes such packages as a group instead of refusing the workspace. The
/// caller is responsible for deferring each group member's standalone
/// resolution check until every member is up — see
/// `publish/cycle_verification.dart`.
///
/// A package that depends on *itself* is rejected at graph-construction time
/// instead, as a [GraphError]: no second upload can ever close that loop.
PublishPlan planPublishOrder(DependencyGraph graph, List<String> targets) {
  // 1. Discover every package reachable from the targets via outgoing edges.
  final reachable = <String>{};
  void visit(String name) {
    if (!reachable.add(name)) return;
    for (final e in graph.outgoing(name)) {
      visit(e.to);
    }
  }

  for (final t in targets) {
    visit(t);
  }

  // 2. Collapse the reachable subgraph to a deduped, name-sorted adjacency
  // map. Deduping matters because a package can depend on the same sibling
  // from both `dependencies` and `dev_dependencies`; sorting keeps the output
  // stable regardless of the order deps happen to appear in a pubspec.
  final neighbors = <String, List<String>>{
    for (final n in reachable)
      n: (graph
          .outgoing(n)
          .map((e) => e.to)
          .where(reachable.contains)
          .toSet()
          .toList()
        ..sort()),
  };

  // 3. Tarjan's strongly-connected-components algorithm.
  //
  // Tarjan pops a component only once every component reachable from it has
  // already been popped. Our edges run dependent -> dependency, so a package's
  // dependencies are always emitted before it: the emission order *is* the
  // publish order, with no separate topological sort needed.
  var nextIndex = 0;
  final index = <String, int>{};
  final lowLink = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final components = <List<String>>[];

  void strongConnect(String v) {
    index[v] = nextIndex;
    lowLink[v] = nextIndex;
    nextIndex++;
    stack.add(v);
    onStack.add(v);

    for (final w in neighbors[v]!) {
      if (!index.containsKey(w)) {
        strongConnect(w);
        lowLink[v] = min(lowLink[v]!, lowLink[w]!);
      } else if (onStack.contains(w)) {
        // Back-edge to a node still on the stack: part of our component.
        lowLink[v] = min(lowLink[v]!, index[w]!);
      }
      // Else: w belongs to an already-emitted component; ignore it.
    }

    if (lowLink[v] != index[v]) return;

    // v roots a component: everything above it on the stack belongs to it.
    final component = <String>[];
    while (true) {
      final w = stack.removeLast();
      onStack.remove(w);
      component.add(w);
      if (w == v) break;
    }
    components.add(component);
  }

  // Seed from the targets in the order given (so a single-target run keeps its
  // familiar shape), then sweep anything reachable but not yet visited.
  for (final t in targets) {
    if (reachable.contains(t) && !index.containsKey(t)) strongConnect(t);
  }
  for (final n in reachable.toList()..sort()) {
    if (!index.containsKey(n)) strongConnect(n);
  }

  // 4. Flatten components into a flat order, recording multi-member ones.
  final order = <String>[];
  final cycles = <List<String>>[];
  for (final component in components) {
    if (component.length == 1) {
      order.add(component.single);
      continue;
    }

    // Inside a cycle no order satisfies every constraint, so pick a stable
    // one: fewest dependencies within the group first (the most leaf-like
    // member, which keeps the unresolvable window as short as possible), then
    // alphabetically.
    final members = component.toSet();
    final sorted = component.toList()
      ..sort((a, b) {
        final aDeps = neighbors[a]!.where(members.contains).length;
        final bDeps = neighbors[b]!.where(members.contains).length;
        return aDeps != bDeps ? aDeps.compareTo(bDeps) : a.compareTo(b);
      });
    order.addAll(sorted);
    cycles.add(sorted);
  }

  return PublishPlan(order: order, cycles: cycles);
}

/// Human-readable rendering of one cycle group, e.g. `a ↔ b` for a mutual
/// pair or `a → b → c → a` for a longer loop.
String describeCycle(List<String> group) => group.length == 2
    ? '${group[0]} ↔ ${group[1]}'
    : '${group.join(' → ')} → ${group.first}';
