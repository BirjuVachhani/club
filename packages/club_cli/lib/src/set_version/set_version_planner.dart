/// Plans version and hosted dependency constraint changes across a workspace.
library;

import 'package:yaml/yaml.dart';

import '../prepare/package_discovery.dart';

enum SetVersionSection {
  dependencies('dependencies'),
  devDependencies('dev_dependencies'),
  dependencyOverrides('dependency_overrides');

  const SetVersionSection(this.key);
  final String key;
}

enum HostedDeclarationShape { shorthand, expanded }

class DependencyConstraintUpdate {
  const DependencyConstraintUpdate({
    required this.section,
    required this.dependencyName,
    required this.newConstraint,
    required this.shape,
  });

  final SetVersionSection section;
  final String dependencyName;
  final String newConstraint;
  final HostedDeclarationShape shape;
}

class SetVersionPackagePlan {
  const SetVersionPackagePlan({
    required this.package,
    required this.newVersion,
    required this.updateTopLevelVersion,
    required this.dependencyUpdates,
  });

  final DiscoveredPackage package;
  final String newVersion;
  final bool updateTopLevelVersion;
  final List<DependencyConstraintUpdate> dependencyUpdates;

  bool get hasChanges => updateTopLevelVersion || dependencyUpdates.isNotEmpty;
}

class SetVersionPlan {
  const SetVersionPlan({
    required this.packages,
    required this.skippedNonHostedReferences,
  });

  final List<SetVersionPackagePlan> packages;
  final int skippedNonHostedReferences;

  int get versionChanges =>
      packages.where((plan) => plan.updateTopLevelVersion).length;

  int get dependencyChanges => packages.fold(
    0,
    (total, plan) => total + plan.dependencyUpdates.length,
  );
}

SetVersionPlan planSetVersion({
  required Map<String, DiscoveredPackage> packages,
  required Set<String> selectedPackageNames,
  required String newVersion,
}) {
  final unknown = selectedPackageNames.difference(packages.keys.toSet());
  if (unknown.isNotEmpty) {
    final names = unknown.toList()..sort();
    throw ArgumentError('Unknown selected packages: ${names.join(', ')}.');
  }

  var skipped = 0;
  final plans = <SetVersionPackagePlan>[];
  final sortedPackages = packages.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  for (final package in sortedPackages) {
    final document = loadYaml(package.rawYaml);
    if (document is! YamlMap) {
      throw FormatException('${package.pubspecPath} must contain a YAML map.');
    }

    final dependencyUpdates = <DependencyConstraintUpdate>[];
    for (final section in SetVersionSection.values) {
      final declarations = document[section.key];
      if (declarations == null) continue;
      if (declarations is! YamlMap) {
        throw FormatException(
          '${package.pubspecPath}: ${section.key} must be a map.',
        );
      }

      for (final entry in declarations.entries) {
        final dependencyName = entry.key?.toString();
        if (dependencyName == null) continue;
        final value = entry.value;
        final targetName = _targetPackageName(dependencyName, value);
        if (targetName == null || !selectedPackageNames.contains(targetName)) {
          continue;
        }

        final constraint = '^$newVersion';
        if (value is YamlMap) {
          if (_isNonHosted(value)) {
            skipped++;
            continue;
          }
          if (!value.containsKey('hosted')) {
            skipped++;
            continue;
          }
          if (value['version']?.toString() == constraint) continue;
          dependencyUpdates.add(
            DependencyConstraintUpdate(
              section: section,
              dependencyName: dependencyName,
              newConstraint: constraint,
              shape: HostedDeclarationShape.expanded,
            ),
          );
        } else {
          if (value?.toString() == constraint) continue;
          dependencyUpdates.add(
            DependencyConstraintUpdate(
              section: section,
              dependencyName: dependencyName,
              newConstraint: constraint,
              shape: HostedDeclarationShape.shorthand,
            ),
          );
        }
      }
    }

    plans.add(
      SetVersionPackagePlan(
        package: package,
        newVersion: newVersion,
        updateTopLevelVersion:
            selectedPackageNames.contains(package.name) &&
            package.pubspec.version?.toString() != newVersion,
        dependencyUpdates: dependencyUpdates,
      ),
    );
  }

  return SetVersionPlan(
    packages: plans,
    skippedNonHostedReferences: skipped,
  );
}

String? _targetPackageName(String dependencyName, Object? value) {
  if (value is! YamlMap) return dependencyName;
  final hosted = value['hosted'];
  if (hosted is YamlMap && hosted['name'] != null) {
    return hosted['name'].toString();
  }
  return dependencyName;
}

bool _isNonHosted(YamlMap declaration) =>
    declaration.containsKey('path') ||
    declaration.containsKey('git') ||
    declaration.containsKey('sdk');
