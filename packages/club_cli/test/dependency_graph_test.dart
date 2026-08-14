import 'dart:io';

import 'package:club_cli/src/prepare/dependency_graph.dart';
import 'package:club_cli/src/prepare/package_discovery.dart';
import 'package:club_cli/src/prepare/rewrite_planner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a throwaway workspace where every key in [deps] becomes a package at
/// version 1.0.0 whose `dependencies` are the listed siblings, declared as
/// `path:` deps. [devDeps] adds the same shape under `dev_dependencies`.
///
/// Returns the discovered packages and the graph built from them, so tests
/// exercise the real discovery path rather than hand-built model objects.
({Map<String, DiscoveredPackage> packages, DependencyGraph graph}) graphFor(
  Map<String, List<String>> deps, {
  Map<String, List<String>> devDeps = const {},
}) {
  final root = Directory.systemTemp.createTempSync('club-graph-test-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  for (final name in {...deps.keys, ...devDeps.keys}) {
    final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    final buf = StringBuffer()
      ..writeln('name: $name')
      ..writeln('version: 1.0.0')
      ..writeln('environment:')
      ..writeln('  sdk: ^3.11.0');

    void writeSection(String key, List<String> targets) {
      if (targets.isEmpty) return;
      buf.writeln('$key:');
      for (final t in targets) {
        buf.writeln('  $t:');
        buf.writeln('    path: ../$t');
      }
    }

    writeSection('dependencies', deps[name] ?? const []);
    writeSection('dev_dependencies', devDeps[name] ?? const []);
    File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(buf.toString());
  }

  final packages = discoverPackages(root.path);
  return (packages: packages, graph: buildDependencyGraph(packages));
}

/// Index of [name] in [order], for asserting relative publish position.
int posOf(List<String> order, String name) {
  final i = order.indexOf(name);
  expect(i, isNot(-1), reason: '$name missing from publish order $order');
  return i;
}

void main() {
  group('acyclic graphs', () {
    test('orders dependencies before dependents', () {
      final g = graphFor({'app': ['core'], 'core': []});
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.order, ['core', 'app']);
      expect(plan.cycles, isEmpty);
      expect(plan.hasCycles, isFalse);
    });

    test('orders a diamond with the shared base first', () {
      final g = graphFor({
        'app': ['left', 'right'],
        'left': ['base'],
        'right': ['base'],
        'base': [],
      });
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.order, hasLength(4));
      expect(plan.cycles, isEmpty);
      expect(posOf(plan.order, 'base'), lessThan(posOf(plan.order, 'left')));
      expect(posOf(plan.order, 'base'), lessThan(posOf(plan.order, 'right')));
      expect(posOf(plan.order, 'left'), lessThan(posOf(plan.order, 'app')));
      expect(posOf(plan.order, 'right'), lessThan(posOf(plan.order, 'app')));
    });

    test('closure excludes packages unreachable from the targets', () {
      final g = graphFor({
        'app': ['core'],
        'core': [],
        'unrelated': [],
      });
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.order, ['core', 'app']);
      expect(plan.order, isNot(contains('unrelated')));
    });
  });

  group('cycles', () {
    // The shape that motivated this: firebase_ui_auth and firebase_ui_oauth
    // depend on each other, and both depend on a shared leaf.
    test('groups a mutual pair and still orders their shared dep first', () {
      final g = graphFor({
        'auth': ['oauth', 'shared'],
        'oauth': ['auth', 'shared'],
        'shared': [],
      });
      final plan = planPublishOrder(g.graph, ['auth']);

      expect(plan.hasCycles, isTrue);
      expect(plan.cycles, [
        ['auth', 'oauth'],
      ]);
      expect(plan.order, ['shared', 'auth', 'oauth']);
      expect(plan.cycleMembers, {'auth', 'oauth'});
    });

    test('cycleFor maps every member to its group and others to null', () {
      final g = graphFor({
        'auth': ['oauth'],
        'oauth': ['auth'],
        'shared': [],
        'app': ['auth', 'shared'],
      });
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.cycleFor('auth'), ['auth', 'oauth']);
      expect(plan.cycleFor('oauth'), ['auth', 'oauth']);
      expect(plan.cycleFor('shared'), isNull);
      expect(plan.cycleFor('app'), isNull);
    });

    test('groups a three-package cycle as one component', () {
      final g = graphFor({'a': ['b'], 'b': ['c'], 'c': ['a']});
      final plan = planPublishOrder(g.graph, ['a']);

      expect(plan.cycles, hasLength(1));
      expect(plan.cycles.single, unorderedEquals(['a', 'b', 'c']));
      expect(plan.order, hasLength(3));
    });

    test('reports two independent cycles separately', () {
      final g = graphFor({
        'a': ['b'],
        'b': ['a'],
        'c': ['d'],
        'd': ['c'],
        'app': ['a', 'c'],
      });
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.cycles, hasLength(2));
      expect(plan.cycleMembers, {'a', 'b', 'c', 'd'});
      expect(plan.order.last, 'app');
    });

    test('a cycle outside the target closure is not reported', () {
      final g = graphFor({
        'app': ['core'],
        'core': [],
        'x': ['y'],
        'y': ['x'],
      });
      final plan = planPublishOrder(g.graph, ['app']);

      expect(plan.cycles, isEmpty);
      expect(plan.order, ['core', 'app']);
    });

    test('a dev_dependency closes a cycle just like a dependency', () {
      // b depends on a, and a dev-depends back on b. Both sections ship in
      // the published pubspec, so this is a real cycle.
      final g = graphFor(
        {'a': [], 'b': ['a']},
        devDeps: {'a': ['b']},
      );
      final plan = planPublishOrder(g.graph, ['b']);

      expect(plan.cycles, [
        ['a', 'b'],
      ]);
    });

    test('non-cycle dependents publish after the group they depend on', () {
      final g = graphFor({
        'a': ['b'],
        'b': ['a'],
        'c': ['a', 'b'],
      });
      final plan = planPublishOrder(g.graph, ['c']);

      expect(plan.cycles, [
        ['a', 'b'],
      ]);
      expect(plan.order.last, 'c');
    });

    test('orders group members by intra-group dep count, then name', () {
      // a -> b, a -> c, b -> c, c -> a. All three are one component.
      // Intra-group out-degrees: b=1, c=1, a=2, so b and c (tied, sorted
      // alphabetically) come before a.
      final g = graphFor({
        'a': ['b', 'c'],
        'b': ['c'],
        'c': ['a'],
      });
      final plan = planPublishOrder(g.graph, ['a']);

      expect(plan.cycles.single, ['b', 'c', 'a']);
      expect(plan.order, ['b', 'c', 'a']);
    });

    test('is deterministic across repeated runs', () {
      final g = graphFor({
        'auth': ['oauth', 'shared'],
        'oauth': ['auth', 'shared'],
        'shared': [],
        'app': ['auth'],
      });

      final first = planPublishOrder(g.graph, ['app']);
      final second = planPublishOrder(g.graph, ['app']);

      expect(second.order, first.order);
      expect(second.cycles, first.cycles);
    });

    test('an all-cycle closure still produces a complete order', () {
      final g = graphFor({'a': ['b'], 'b': ['a']});
      final plan = planPublishOrder(g.graph, ['a']);

      expect(plan.order, ['a', 'b']);
      expect(plan.cycles, [
        ['a', 'b'],
      ]);
    });
  });

  group('self-dependency', () {
    test('is a graph error rather than a cycle group', () {
      final g = graphFor({'a': ['a']});

      expect(g.graph.errors, hasLength(1));
      expect(g.graph.errors.single.message, contains('depend on itself'));
      expect(g.graph.edges, isEmpty);

      // No self-edge means no bogus single-member cycle downstream.
      final plan = planPublishOrder(g.graph, ['a']);
      expect(plan.cycles, isEmpty);
      expect(plan.order, ['a']);
    });

    test('is caught in dev_dependencies too', () {
      final g = graphFor({'a': []}, devDeps: {'a': ['a']});

      expect(g.graph.errors, hasLength(1));
      expect(g.graph.errors.single.message, contains('dev_dependencies.a'));
    });
  });

  group('describeCycle', () {
    test('renders a mutual pair with a double arrow', () {
      expect(describeCycle(['auth', 'oauth']), 'auth ↔ oauth');
    });

    test('renders a longer loop back to its start', () {
      expect(describeCycle(['a', 'b', 'c']), 'a → b → c → a');
    });
  });

  group('planRewrites over a cycle', () {
    test('rewrites both directions to hosted constraints', () {
      final g = graphFor({
        'auth': ['oauth'],
        'oauth': ['auth'],
      });
      final plan = planPublishOrder(g.graph, ['auth']);

      final plans = planRewrites(
        graph: g.graph,
        order: plan.order,
        serverUrl: 'https://club.example',
      );

      expect(plans, hasLength(2));
      for (final pkgPlan in plans) {
        expect(pkgPlan.rewrites, hasLength(1));
        final rewrite = pkgPlan.rewrites.single;
        expect(rewrite.constraint, '^1.0.0');
        expect(rewrite.declaredAs, DeclarationShape.pathDependency);
        expect(rewrite.depName, isNot(pkgPlan.package.name));
      }
    });
  });
}
