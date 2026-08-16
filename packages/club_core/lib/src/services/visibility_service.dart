import 'dart:convert';

import '../exceptions.dart';
import '../models/audit_log.dart';
import '../models/package.dart';
import '../models/package_version.dart';
import '../models/package_visibility.dart';
import '../models/version_dependency.dart';
import '../repositories/metadata_store.dart';
import '../repositories/visibility_scope.dart';
import '../repositories/settings_store.dart';

/// `server_settings` key for the operator-facing half of the master
/// switch. The other half is the `PUBLIC_PACKAGES_ENABLED` environment
/// variable; both must be true.
const String publicPackagesEnabledKey = 'public_packages_enabled';

/// `server_settings` key for whether flipping a package to public requires
/// a server admin rather than merely a package admin.
const String publicVisibilityRequiresAdminKey =
    'public_visibility_requires_admin';

/// One node of the closure a visibility change would touch.
class VisibilityClosureNode {
  const VisibilityClosureNode({
    required this.package,
    required this.visibility,
    required this.exists,
    required this.isTarget,
    required this.versionCount,
    required this.totalBytes,
    required this.requiredBy,
  });

  final String package;
  final PackageVisibility visibility;

  /// False when an edge points at a package that is not on this server.
  /// Such a node can never resolve, so it is surfaced rather than hidden.
  final bool exists;

  /// True for the package the operator actually named.
  final bool isTarget;

  /// How many versions and how many bytes of archive would become
  /// readable. The confirmation shows these because "make public" reads
  /// as one artifact and is in fact the entire published history.
  final int versionCount;
  final int totalBytes;

  /// Packages in the closure that depend on this one, so the tree can
  /// explain why a node is present at all.
  final List<String> requiredBy;

  Map<String, Object?> toJson() => {
    'package': package,
    'visibility': visibility.wireName,
    'exists': exists,
    'isTarget': isTarget,
    'versionCount': versionCount,
    'totalBytes': totalBytes,
    'requiredBy': requiredBy,
  };
}

/// A bare dependency whose name also exists on this server.
class AmbiguousDependency {
  const AmbiguousDependency({
    required this.package,
    required this.version,
    required this.dependency,
    this.constraint,
  });

  final String package;
  final String version;
  final String dependency;
  final String? constraint;

  Map<String, Object?> toJson() => {
    'package': package,
    'version': version,
    'dependency': dependency,
    'constraint': constraint,
  };
}

/// A version that would not appear in the anonymous version list, and the
/// dependencies that keep it out.
class UnresolvableVersion {
  const UnresolvableVersion({
    required this.package,
    required this.version,
    required this.blockedBy,
  });

  final String package;
  final String version;

  /// The club-hosted dependencies of this version that would still be
  /// private after the change.
  final List<String> blockedBy;

  Map<String, Object?> toJson() => {
    'package': package,
    'version': version,
    'blockedBy': blockedBy,
  };
}

/// What a proposed visibility change would actually do.
class VisibilityPreview {
  const VisibilityPreview({
    required this.package,
    required this.target,
    required this.current,
    required this.closure,
    required this.selected,
    required this.devOnly,
    required this.ambiguous,
    required this.unresolvableVersions,
    required this.publicDependents,
    required this.blockedReason,
  });

  final String package;
  final PackageVisibility target;
  final PackageVisibility current;

  /// Everything the change could touch, target first.
  final List<VisibilityClosureNode> closure;

  /// The subset that would actually be flipped. Defaults to the whole
  /// closure; shrinks as the operator deselects.
  final List<String> selected;

  /// Club-hosted packages reachable only through `dev_dependencies`.
  /// Informational: a dependency's dev dependencies are never resolved by
  /// a consumer, so leaving these private breaks nobody downstream.
  final List<VisibilityClosureNode> devOnly;

  final List<AmbiguousDependency> ambiguous;

  /// Versions that would be absent from the anonymous version list under
  /// [selected]. Empty when the whole closure is selected.
  final List<UnresolvableVersion> unresolvableVersions;

  /// For a public-to-private change: what breaks.
  final List<DependentPath> publicDependents;

  /// Non-null when the change cannot be applied at all.
  final String? blockedReason;

  bool get isBlocked => blockedReason != null;

  Map<String, Object?> toJson() => {
    'package': package,
    'target': target.wireName,
    'current': current.wireName,
    'closure': [for (final n in closure) n.toJson()],
    'selected': selected,
    'devOnly': [for (final n in devOnly) n.toJson()],
    'ambiguousBareDependencies': [for (final a in ambiguous) a.toJson()],
    'unresolvableVersions': [
      for (final v in unresolvableVersions) v.toJson(),
    ],
    'publicDependents': [
      for (final d in publicDependents)
        {'package': d.package, 'path': d.path},
    ],
    'blockedReason': blockedReason,
  };
}

/// Owns every transition of `packages.visibility`.
///
/// Nothing else may write that column. A flip has consequences beyond the
/// one row (recomputing `public_resolvable` for dependents, an audit
/// record, a reverse-dependency check), and a bare `updatePackage` that
/// set it directly would leave the database internally inconsistent while
/// looking like it had worked.
class VisibilityService {
  VisibilityService({
    required MetadataStore store,
    required SettingsStore settings,
    required String Function() generateId,
    required bool envEnabled,
  }) : _store = store,
       _settings = settings,
       _generateId = generateId,
       _envEnabled = envEnabled;

  final MetadataStore _store;
  final SettingsStore _settings;
  final String Function() _generateId;

  /// The `PUBLIC_PACKAGES_ENABLED` environment variable.
  final bool _envEnabled;

  /// Whether public packages are available on this server at all.
  ///
  /// Both halves must agree. The environment variable is controlled by
  /// whoever controls the deployment; the setting by whoever controls the
  /// dashboard. Requiring both means an existing deployment cannot grow
  /// an anonymous surface because someone ticked a checkbox, and an
  /// operator can kill the whole feature from the environment without
  /// touching any package's state.
  ///
  /// Turning either off makes every public package require credentials
  /// again immediately, with no per-package change. That is the kill
  /// switch, and it is why the gate is read per request rather than
  /// cached at boot.
  Future<bool> isEnabled() async {
    if (!_envEnabled) return false;
    return await _settings.getSetting(publicPackagesEnabledKey) == 'true';
  }

  /// True when the environment permits public packages, so the dashboard
  /// can offer the toggle at all. Distinct from [isEnabled], which also
  /// requires the toggle to be on.
  bool get isPermittedByEnvironment => _envEnabled;

  Future<void> setEnabled(bool enabled) =>
      _settings.setSetting(publicPackagesEnabledKey, '$enabled');

  /// Whether flipping to public needs a server admin rather than any
  /// package admin. Defaults to false, matching the chosen model where a
  /// package admin self-serves. Operators who want a human in the loop
  /// turn it on.
  Future<bool> requiresServerAdmin() async =>
      await _settings.getSetting(publicVisibilityRequiresAdminKey) == 'true';

  Future<void> setRequiresServerAdmin(bool value) =>
      _settings.setSetting(publicVisibilityRequiresAdminKey, '$value');

  /// Work out what changing [package] to [target] would do, without
  /// changing anything.
  ///
  /// [selected] is the operator's current choice of which closure members
  /// to flip alongside the target. Null means "all of them", which is the
  /// default the UI opens with and the only choice that leaves no version
  /// unresolvable.
  Future<VisibilityPreview> preview({
    required String package,
    required PackageVisibility target,
    Set<String>? selected,
  }) async {
    final pkg = await _store.lookupPackage(package);
    if (pkg == null) throw NotFoundException.package(package);

    return target.isPublic
        ? _previewPublic(pkg, selected)
        : _previewPrivate(pkg, selected);
  }

  Future<VisibilityPreview> _previewPublic(
    Package pkg,
    Set<String>? selected,
  ) async {
    final closureNames = await _store.localDependencyClosure({pkg.name});

    // Everything reachable when dev dependencies are followed too, minus
    // what is required without them. Reported separately and never
    // selected: a dependency's dev dependencies are not resolved by any
    // consumer, so making them public would expose source for nothing.
    final withDev = await _store.localDependencyClosure(
      {pkg.name},
      includeDev: true,
    );
    final devOnlyNames = withDev.difference(closureNames);

    final chosen = selected ?? closureNames;
    // The target itself is never optional. Deselecting it would make the
    // whole request a no-op wearing the shape of a change.
    final effective = {...chosen.intersection(closureNames), pkg.name};

    final closure = await _buildNodes(closureNames, pkg.name);
    final devOnly = await _buildNodes(devOnlyNames, pkg.name);

    // Under this selection, which versions could an anonymous client not
    // resolve? A package is treated as public if it already is or if the
    // operator selected it.
    Future<bool> willBePublic(String name) async {
      if (effective.contains(name)) return true;
      final p = await _store.lookupPackage(name);
      return p != null && p.isPublic;
    }

    final unresolvable = <UnresolvableVersion>[];
    for (final name in effective) {
      for (final version in await _store.listVersions(
        name,
        scope: VisibilityScope.trustedInternal,
      )) {
        final blockers = <String>[];
        for (final dep in await _store.listVersionDependencies(
          name,
          version.version,
        )) {
          if (!dep.participatesInClosure) continue;
          if (!await willBePublic(dep.name)) blockers.add(dep.name);
        }
        if (blockers.isNotEmpty) {
          unresolvable.add(
            UnresolvableVersion(
              package: name,
              version: version.version,
              blockedBy: blockers..sort(),
            ),
          );
        }
      }
    }

    final ambiguous = await _collectAmbiguous(effective);

    // A package whose every version is blocked would be "public" and
    // simultaneously impossible to resolve. That is a state nobody asked
    // for, so it is refused rather than created.
    String? blocked;
    final targetVersions = await _store.listVersions(
      pkg.name,
      scope: VisibilityScope.trustedInternal,
    );
    if (targetVersions.isNotEmpty) {
      final blockedForTarget = unresolvable
          .where((u) => u.package == pkg.name)
          .length;
      if (blockedForTarget == targetVersions.length) {
        blocked =
            'No version of ${pkg.name} could be resolved without '
            'credentials under this selection. Include its club-hosted '
            'dependencies, or keep the package private.';
      }
    }

    return VisibilityPreview(
      package: pkg.name,
      target: PackageVisibility.public,
      current: pkg.visibility,
      closure: closure,
      selected: effective.toList()..sort(),
      devOnly: devOnly,
      ambiguous: ambiguous,
      unresolvableVersions: unresolvable
        ..sort((a, b) {
          final byPackage = a.package.compareTo(b.package);
          return byPackage != 0 ? byPackage : a.version.compareTo(b.version);
        }),
      publicDependents: const [],
      blockedReason: blocked,
    );
  }

  Future<VisibilityPreview> _previewPrivate(
    Package pkg,
    Set<String>? selected,
  ) async {
    // The hazard nobody asks about: making this private breaks every
    // public package that depends on it. Surfaced with a concrete path
    // each, because "3 packages will break" is not actionable but
    // "app -> core_ui -> icons" is.
    final dependents = await _store.findPublicDependents(pkg.name);

    // Offer the cascade the operator probably wants: this package plus
    // everything it pulled public in the first place, minus anything a
    // package outside the cascade still needs.
    final candidates = await _store.localDependencyClosure({pkg.name});
    final chosen = selected ?? {pkg.name};
    final effective = {...chosen.intersection(candidates), pkg.name};

    final closure = await _buildNodes(candidates, pkg.name);

    return VisibilityPreview(
      package: pkg.name,
      target: PackageVisibility.private,
      current: pkg.visibility,
      closure: closure,
      selected: effective.toList()..sort(),
      devOnly: const [],
      ambiguous: const [],
      unresolvableVersions: const [],
      publicDependents: dependents,
      blockedReason: null,
    );
  }

  Future<List<VisibilityClosureNode>> _buildNodes(
    Set<String> names,
    String target,
  ) async {
    // Who requires whom, so the tree can say why a package is listed.
    final requiredBy = <String, List<String>>{};
    for (final name in names) {
      for (final version in await _store.listVersions(
        name,
        scope: VisibilityScope.trustedInternal,
      )) {
        for (final dep in await _store.listVersionDependencies(
          name,
          version.version,
        )) {
          if (!dep.participatesInClosure) continue;
          if (!names.contains(dep.name)) continue;
          final list = requiredBy.putIfAbsent(dep.name, () => []);
          if (!list.contains(name)) list.add(name);
        }
      }
    }

    final nodes = <VisibilityClosureNode>[];
    for (final name in names) {
      final pkg = await _store.lookupPackage(name);
      final versions = pkg == null
          ? const <PackageVersion>[]
          : await _store.listVersions(
        name,
        scope: VisibilityScope.trustedInternal,
      );
      nodes.add(
        VisibilityClosureNode(
          package: name,
          visibility: pkg?.visibility ?? PackageVisibility.private,
          exists: pkg != null,
          isTarget: name == target,
          versionCount: versions.length,
          totalBytes: versions.fold<int>(0, (a, v) => a + v.archiveSizeBytes),
          requiredBy: [...?requiredBy[name]]..sort(),
        ),
      );
    }

    nodes.sort((a, b) {
      if (a.isTarget != b.isTarget) return a.isTarget ? -1 : 1;
      return a.package.compareTo(b.package);
    });
    return nodes;
  }

  Future<List<AmbiguousDependency>> _collectAmbiguous(
    Set<String> names,
  ) async {
    final result = <AmbiguousDependency>[];
    for (final name in names) {
      for (final version in await _store.listVersions(
        name,
        scope: VisibilityScope.trustedInternal,
      )) {
        for (final dep in await _store.listVersionDependencies(
          name,
          version.version,
        )) {
          if (!dep.isAmbiguous) continue;
          if (dep.kind != DependencyKind.direct) continue;
          result.add(
            AmbiguousDependency(
              package: name,
              version: version.version,
              dependency: dep.name,
              constraint: dep.constraintText,
            ),
          );
        }
      }
    }
    return result;
  }

  /// Apply a visibility change to [package] and everything in [closure].
  ///
  /// One transaction: either every package in the set flips and the
  /// derived flags and audit records go with it, or none does. A partial
  /// flip is the one outcome that must not be possible, because it means
  /// a package is public while something it needs is not.
  ///
  /// [acceptBreakage] is required when going private would break public
  /// dependents that are not themselves in [closure]. There is no default:
  /// the caller has to have seen the list and said which way.
  Future<VisibilityPreview> apply({
    required String package,
    required PackageVisibility target,
    required Set<String> closure,
    required String actorUserId,
    bool acceptBreakage = false,
  }) async {
    if (!await isEnabled()) {
      throw const ForbiddenException(
        'Public packages are not enabled on this server.',
      );
    }

    final preview = await this.preview(
      package: package,
      target: target,
      selected: closure,
    );

    if (preview.isBlocked) {
      throw InvalidInputException(preview.blockedReason!);
    }

    if (!target.isPublic) {
      // Dependents that the cascade does not already cover are the ones
      // that actually break.
      final collateral = preview.publicDependents
          .where((d) => !preview.selected.contains(d.package))
          .toList();
      if (collateral.isNotEmpty && !acceptBreakage) {
        final summary = collateral
            .take(5)
            .map((d) => d.pathDescription)
            .join('; ');
        throw ConflictException(
          'Making $package private breaks ${collateral.length} public '
          'package(s) that depend on it: $summary'
          '${collateral.length > 5 ? '; ...' : ''}. Include them in the '
          'change, or confirm you accept the breakage.',
        );
      }
    }

    final now = DateTime.now().toUtc();
    final flipped = <String>[];

    await _store.transaction((tx) async {
      for (final name in preview.selected) {
        final pkg = await tx.lookupPackage(name);
        if (pkg == null) continue;
        if (pkg.visibility == target) continue;

        await tx.updatePackage(
          name,
          PackageCompanion(
            name: name,
            visibility: target,
            visibilityChangedAt: now,
            visibilityChangedBy: actorUserId,
          ),
        );
        flipped.add(name);
      }

      if (flipped.isEmpty) return;

      // Recompute the derived flag for everything whose answer could have
      // moved: the flipped packages themselves, plus anything declaring a
      // direct club-hosted dependency on one of them. Scoped rather than
      // global so a flip stays cheap on a large registry.
      final affected = <String>{
        ...flipped,
        ...await tx.packagesDependingOn(flipped.toSet()),
      };
      await tx.recomputePublicResolvable(affected);

      // One record per package, each naming the whole set it moved with,
      // so the log answers "what else went public in this action" from
      // any single entry.
      for (final name in flipped) {
        await tx.appendAuditLog(
          AuditLogCompanion(
            id: _generateId(),
            kind: target.isPublic
                ? AuditKind.packageMadePublic
                : AuditKind.packageMadePrivate,
            agentId: actorUserId,
            packageName: name,
            summary: target.isPublic
                ? '$name made public'
                  '${name == package ? '' : ' (required by $package)'}.'
                : '$name made private'
                  '${name == package ? '' : ' (with $package)'}.',
            dataJson: jsonEncode({
              'requestedPackage': package,
              'closure': flipped,
              if (!target.isPublic && acceptBreakage)
                'acceptedBreakage': [
                  for (final d in preview.publicDependents)
                    if (!preview.selected.contains(d.package)) d.package,
                ],
            }),
          ),
        );
      }
    });

    return this.preview(package: package, target: target, selected: closure);
  }

  /// Guard for deleting a package or a version: report the public
  /// packages that would stop resolving.
  ///
  /// Deletion is the same hazard as going private, with no undo at all,
  /// so it runs the same check.
  Future<List<DependentPath>> breakageFromRemoving(String package) =>
      _store.findPublicDependents(package);
}
