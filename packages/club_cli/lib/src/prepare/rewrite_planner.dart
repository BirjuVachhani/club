/// Turns a [DependencyGraph] + selected publish order into the concrete list
/// of pubspec edits we want to apply.
///
/// One [PackagePlan] per package in the closure. The plan lists every
/// internal-dep edge that needs to be rewritten to a hosted reference.
library;

import 'conflict_resolver.dart';
import 'dependency_graph.dart';
import 'package_discovery.dart';

/// All planned changes for a single pubspec.yaml.
class PackagePlan {
  PackagePlan({
    required this.package,
    required this.rewrites,
  });

  final DiscoveredPackage package;
  final List<DepRewrite> rewrites;
}

/// Raised when planning hits a package that needs a version but doesn't
/// have one in its pubspec. Carries the names of all such packages so the
/// user can see every gap in one report.
class MissingVersionError implements Exception {
  MissingVersionError(this.packageNames);
  final List<String> packageNames;
  @override
  String toString() => packageNames.length == 1
      ? '${packageNames.single} has no version field in pubspec.yaml.'
      : 'Packages without version fields: ${packageNames.join(', ')}';
}

/// One dep entry to rewrite in a single pubspec.yaml.
class DepRewrite {
  DepRewrite({
    required this.section,
    required this.depName,
    required this.targetVersion,
    required this.serverUrl,
    required this.declaredAs,
  });

  final DepSection section;
  final String depName;

  /// The version of the *target* package (the package being depended on),
  /// taken from its own pubspec.yaml. Written as `^<targetVersion>`.
  final String targetVersion;
  final String serverUrl;
  final DeclarationShape declaredAs;

  /// Constraint string written into the pubspec, e.g. `^1.2.3`.
  String get constraint => '^$targetVersion';
}

/// Build per-package plans for every package in [order].
///
/// Only edges where the depending package is in [order] *and* the
/// depended-on package is in [order] become rewrites. (If a target picks
/// pkg_a, the closure includes pkg_a's transitive deps but not unrelated
/// packages.)
///
/// [actions] selects what we will do with each package — packages marked
/// [PackageAction.skip] do not get a [PackagePlan] (their pubspec is
/// untouched because we're reusing the already-published version), but
/// dependents still rewrite to point at that published version since the
/// local pubspec version equals it.
///
/// Throws [MissingVersionError] when a package referenced as a rewrite
/// target has no version field in its pubspec — the rewrite needs a real
/// version to write `^X.Y.Z` into the dependent.
List<PackagePlan> planRewrites({
  required DependencyGraph graph,
  required List<String> order,
  required String serverUrl,
  Map<String, PackageAction> actions = const {},
}) {
  final inOrder = order.toSet();
  final plans = <PackagePlan>[];
  final missing = <String>{};

  for (final name in order) {
    final action = actions[name] ?? PackageAction.publishNew;
    if (action == PackageAction.skip) continue;

    final pkg = graph.packages[name]!;
    final rewrites = <DepRewrite>[];

    for (final edge in graph.outgoing(name)) {
      if (!inOrder.contains(edge.to)) continue;
      final target = graph.packages[edge.to]!;
      final targetVersion = target.version;
      if (targetVersion == null) {
        missing.add(edge.to);
        continue;
      }
      rewrites.add(
        DepRewrite(
          section: edge.section,
          depName: edge.to,
          targetVersion: targetVersion,
          serverUrl: serverUrl,
          declaredAs: edge.declaredAs,
        ),
      );
    }

    plans.add(PackagePlan(package: pkg, rewrites: rewrites));
  }

  if (missing.isNotEmpty) {
    throw MissingVersionError(missing.toList()..sort());
  }

  return plans;
}
