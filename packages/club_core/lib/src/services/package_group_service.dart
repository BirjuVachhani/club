import 'dart:convert';

import '../authz/permissions.dart';
import '../exceptions.dart';
import '../models/audit_log.dart';
import '../models/package_group.dart';
import '../models/search.dart';
import '../repositories/metadata_store.dart';
import '../repositories/search_index.dart';
import 'package_service.dart';

/// Manages visual package groups without changing package authorization.
class PackageGroupService {
  PackageGroupService({
    required MetadataStore store,
    required SearchIndex searchIndex,
    required PackageService packageService,
    required this.generateId,
  }) : _store = store,
       _searchIndex = searchIndex,
       _packageService = packageService;

  final MetadataStore _store;
  final SearchIndex _searchIndex;
  final PackageService _packageService;
  final String Function() generateId;

  Future<PackageGroup> create({
    required String name,
    String? description,
    String? publisherId,
    required String actingUserId,
  }) async {
    final actor = await _store.lookupUserById(actingUserId);
    if (actor == null) throw NotFoundException.user(actingUserId);
    if (!Permissions.canPublish(actor.role)) {
      throw ForbiddenException.notAdmin();
    }
    if (publisherId != null &&
        !actor.isAdmin &&
        !await _store.isPublisherAdmin(publisherId, actingUserId)) {
      throw ForbiddenException.notAdmin();
    }

    final normalizedName = _validateName(name);
    final slug = await _availableSlug(_slugify(normalizedName));
    final group = await _store.createPackageGroup(
      PackageGroupCompanion(
        id: generateId(),
        slug: slug,
        name: normalizedName,
        description: _normalizeDescription(description),
        ownerUserId: publisherId == null ? actingUserId : null,
        publisherId: publisherId,
        createdBy: actingUserId,
      ),
    );
    await _searchIndex.indexPackageGroup(
      PackageGroupIndexDocument.fromGroup(group),
    );
    await _audit(
      group,
      AuditKind.packageGroupCreated,
      actingUserId,
      'Package group "${group.name}" created.',
    );
    return group;
  }

  Future<bool> canManage(String groupId, String userId) async {
    final actor = await _store.lookupUserById(userId);
    if (actor?.isAdmin ?? false) return true;
    final group = await _requireGroup(groupId);
    if (group.ownerUserId == userId) return true;
    return group.publisherId != null &&
        await _store.isPublisherAdmin(group.publisherId!, userId);
  }

  Future<PackageGroup> createAndAdd({
    required String packageName,
    required String name,
    String? description,
    String? publisherId,
    required String actingUserId,
  }) async {
    final group = await create(
      name: name,
      description: description,
      publisherId: publisherId,
      actingUserId: actingUserId,
    );
    try {
      await addPackage(group.id, packageName, actingUserId: actingUserId);
      return group;
    } catch (_) {
      await _store.deletePackageGroup(group.id);
      await _searchIndex.removePackageGroup(group.id);
      rethrow;
    }
  }

  Future<PackageGroup> createAndMove({
    required String packageName,
    required String fromGroupId,
    required String name,
    String? description,
    String? publisherId,
    required String actingUserId,
  }) async {
    final group = await create(
      name: name,
      description: description,
      publisherId: publisherId,
      actingUserId: actingUserId,
    );
    try {
      await movePackage(
        packageName: packageName,
        fromGroupId: fromGroupId,
        toGroupId: group.id,
        actingUserId: actingUserId,
      );
      return group;
    } catch (_) {
      await _store.deletePackageGroup(group.id);
      await _searchIndex.removePackageGroup(group.id);
      rethrow;
    }
  }

  Future<PackageGroup> update(
    String groupId, {
    required String name,
    String? description,
    required String actingUserId,
  }) async {
    await _requireManage(groupId, actingUserId);
    final updated = await _store.updatePackageGroup(
      groupId,
      name: _validateName(name),
      description: _normalizeDescription(description),
    );
    await _searchIndex.indexPackageGroup(
      PackageGroupIndexDocument.fromGroup(updated),
    );
    await _audit(
      updated,
      AuditKind.packageGroupUpdated,
      actingUserId,
      'Package group "${updated.name}" updated.',
    );
    return updated;
  }

  Future<void> delete(String groupId, {required String actingUserId}) async {
    final group = await _requireGroup(groupId);
    await _requireManage(groupId, actingUserId);
    await _store.transaction((tx) async {
      await tx.deletePackageGroup(groupId);
      await tx.appendAuditLog(
        AuditLogCompanion(
          id: generateId(),
          kind: AuditKind.packageGroupDeleted,
          agentId: actingUserId,
          summary: 'Package group "${group.name}" deleted.',
          dataJson: jsonEncode({'groupId': group.id, 'slug': group.slug}),
        ),
      );
    });
    await _searchIndex.removePackageGroup(groupId);
  }

  Future<void> addPackage(
    String groupId,
    String packageName, {
    required String actingUserId,
  }) async {
    final group = await _requireGroup(groupId);
    await _requireMembershipAuthority(groupId, packageName, actingUserId);
    if (await _store.lookupPackage(packageName) == null) {
      throw NotFoundException.package(packageName);
    }
    await _store.addPackageToGroup(groupId, packageName, addedBy: actingUserId);
    await _audit(
      group,
      AuditKind.packageGroupPackageAdded,
      actingUserId,
      '$packageName added to package group "${group.name}".',
      packageName: packageName,
    );
  }

  Future<void> removePackage(
    String groupId,
    String packageName, {
    required String actingUserId,
  }) async {
    final group = await _requireGroup(groupId);
    await _requireMembershipAuthority(groupId, packageName, actingUserId);
    await _store.removePackageFromGroup(groupId, packageName);
    await _audit(
      group,
      AuditKind.packageGroupPackageRemoved,
      actingUserId,
      '$packageName removed from package group "${group.name}".',
      packageName: packageName,
    );
  }

  Future<void> movePackage({
    required String packageName,
    required String fromGroupId,
    required String toGroupId,
    required String actingUserId,
  }) async {
    final source = await _requireGroup(fromGroupId);
    await _requireGroup(toGroupId);
    await _requireMembershipAuthority(fromGroupId, packageName, actingUserId);
    await _requireMembershipAuthority(toGroupId, packageName, actingUserId);
    await _store.movePackageBetweenGroups(
      packageName,
      fromGroupId: fromGroupId,
      toGroupId: toGroupId,
      addedBy: actingUserId,
    );
    await _audit(
      source,
      AuditKind.packageGroupPackageMoved,
      actingUserId,
      '$packageName moved between package groups.',
      packageName: packageName,
      extra: {'toGroupId': toGroupId},
    );
  }

  Future<void> replacePackages(
    String groupId,
    List<String> packageNames, {
    required String actingUserId,
  }) async {
    final group = await _requireGroup(groupId);
    await _requireManage(groupId, actingUserId);
    for (final packageName in packageNames) {
      if (await _store.lookupPackage(packageName) == null) {
        throw NotFoundException.package(packageName);
      }
    }
    await _store.replacePackageGroupPackages(
      groupId,
      packageNames,
      addedBy: actingUserId,
    );
    await _audit(
      group,
      AuditKind.packageGroupUpdated,
      actingUserId,
      'Packages updated in package group "${group.name}".',
    );
  }

  Future<void> reorder(
    String groupId,
    List<String> packageNames, {
    required String actingUserId,
  }) async {
    final group = await _requireGroup(groupId);
    await _requireManage(groupId, actingUserId);
    await _store.reorderPackageGroup(groupId, packageNames);
    await _audit(
      group,
      AuditKind.packageGroupReordered,
      actingUserId,
      'Packages reordered in package group "${group.name}".',
    );
  }

  Future<PackageGroup> _requireGroup(String id) async {
    final group = await _store.lookupPackageGroup(id);
    if (group == null) throw NotFoundException.packageGroup(id);
    return group;
  }

  Future<void> _requireManage(String groupId, String userId) async {
    if (!await canManage(groupId, userId)) throw ForbiddenException.notAdmin();
  }

  Future<void> _requireMembershipAuthority(
    String groupId,
    String packageName,
    String userId,
  ) async {
    if (await canManage(groupId, userId)) return;
    if (await _packageService.isPackageAdmin(packageName, userId)) return;
    throw ForbiddenException.notAdmin();
  }

  String _validateName(String name) {
    final value = name.trim();
    if (value.isEmpty || value.length > 80) {
      throw const InvalidInputException(
        'Group name must contain between 1 and 80 characters.',
      );
    }
    return value;
  }

  String? _normalizeDescription(String? description) {
    final value = description?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.length > 1000) {
      throw const InvalidInputException(
        'Group description cannot exceed 1000 characters.',
      );
    }
    return value;
  }

  String _slugify(String name) {
    var slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'group' : slug;
  }

  Future<String> _availableSlug(String base) async {
    var slug = base;
    var suffix = 2;
    while (await _store.lookupPackageGroupBySlug(slug) != null) {
      slug = '$base-${suffix++}';
    }
    return slug;
  }

  Future<void> _audit(
    PackageGroup group,
    String kind,
    String actor,
    String summary, {
    String? packageName,
    Map<String, Object?> extra = const {},
  }) {
    return _store.appendAuditLog(
      AuditLogCompanion(
        id: generateId(),
        kind: kind,
        agentId: actor,
        packageName: packageName,
        publisherId: group.publisherId,
        summary: summary,
        dataJson: jsonEncode({
          'groupId': group.id,
          'slug': group.slug,
          ...extra,
        }),
      ),
    );
  }
}
