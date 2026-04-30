/// Central permission matrix for the club server.
///
/// Every handler and service that gates behaviour on role should call a
/// predicate here rather than inspect roles directly — this keeps the
/// authorization rules in one place and makes the test matrix obvious.
///
/// The rules follow the design docs:
///
/// | Action                      | Owner | Admin | Editor | Viewer |
/// |-----------------------------|:-----:|:-----:|:------:|:------:|
/// | Read / download packages    |   ✓   |   ✓   |   ✓    |   ✓    |
/// | Publish / edit metadata     |   ✓   |   ✓   |   ✓    |        |
/// | Verify a publisher domain   |   ✓   |   ✓   |   ✓    |        |
/// | Create an internal publisher|   ✓   |   ✓   |        |        |
/// | Delete package or version   |   ✓   |   ✓   |        |        |
/// | Manage users                |   ✓   |   ✓   |        |        |
/// | Transfer ownership          |   ✓   |       |        |        |
/// | Server-level settings       |   ✓   |       |        |        |
///
/// Publisher management (edit, members, delete a specific publisher) is
/// orthogonal — gated on publisher-membership rather than server role.
/// Server admins may bypass publisher-membership checks.
///
/// Admin may not mutate the owner (role change, disable, delete, reset pw);
/// all such attempts should go through [canModifyUser] which encodes the
/// "hands off the owner" rule.
library;

import '../models/user_role.dart';

abstract final class Permissions {
  // ── Package-level actions ─────────────────────────────────────────────

  /// Read packages, archives, and public metadata.
  static bool canReadPackages(UserRole role) => role.isAtLeast(UserRole.viewer);

  /// Publish new versions and edit package/version metadata.
  static bool canPublish(UserRole role) => role.isAtLeast(UserRole.member);

  /// Retract or unretract a package version.
  static bool canRetract(UserRole role) => role.isAtLeast(UserRole.member);

  /// Hard-delete a package or a specific version. Editors cannot delete
  /// per the design ("Can't delete them").
  static bool canDeletePackage(UserRole role) => role.isAtLeast(UserRole.admin);

  /// Add or remove uploaders on a package they own. Editors may manage
  /// uploaders on packages they themselves uploaded; admins+ can manage
  /// anywhere.
  static bool canManageUploaders(UserRole role) =>
      role.isAtLeast(UserRole.member);

  /// Start a DNS-based publisher verification. Any authenticated user
  /// at editor+ may attempt; the verification itself still requires
  /// proving control of the domain via a TXT record.
  static bool canVerifyPublisher(UserRole role) =>
      role.isAtLeast(UserRole.member);

  /// Create an internal (unverified, arbitrary-slug) publisher. Reserved
  /// for server admins because internal publishers bypass domain proof —
  /// the trust model is "the admin vouches for the namespace".
  static bool canCreateInternalPublisher(UserRole role) =>
      role.isAtLeast(UserRole.admin);

  /// Legacy predicate — kept for callers that just want the "is this user
  /// allowed to touch the publisher surface at all?" check. Server admins
  /// can do everything; editors can at least verify new publishers.
  static bool canManagePublishers(UserRole role) =>
      role.isAtLeast(UserRole.member);

  // ── User management ───────────────────────────────────────────────────

  /// List / create / update / disable / delete users, and reset their
  /// passwords.
  static bool canManageUsers(UserRole role) => role.isAtLeast(UserRole.admin);

  /// Can [actor] perform any mutation (role change, disable, delete,
  /// password reset) on [target]?
  ///
  /// Four hard invariants, in order:
  ///   1. Actor must have user-management permission.
  ///   2. Nobody (not even the owner) can touch themselves via admin APIs
  ///      — this prevents lockout. Self-service uses dedicated endpoints
  ///      like [changePassword] or a future "leave server" flow.
  ///   3. Only the owner may touch another owner.
  ///   4. An admin may not touch an owner — the owner is untouchable by
  ///      anyone except themselves.
  static bool canModifyUser({
    required UserRole actor,
    required String actorId,
    required UserRole target,
    required String targetId,
  }) {
    if (!canManageUsers(actor)) return false;
    if (actorId == targetId) return false;
    if (target == UserRole.owner && actor != UserRole.owner) return false;
    return true;
  }

  /// Who can assign which roles?
  ///
  /// - Only the owner can assign the owner role (and that's technically
  ///   handled via [canTransferOwnership] in a single transaction — not
  ///   via a role-change call).
  /// - Admins and the owner can assign any non-owner role.
  /// - Editors and viewers cannot assign any role.
  static bool canAssignRole({
    required UserRole actor,
    required UserRole newRole,
  }) {
    if (!canManageUsers(actor)) return false;
    if (newRole == UserRole.owner) return actor == UserRole.owner;
    return true;
  }

  // ── Server-level / operator ───────────────────────────────────────────

  /// Transfer the owner role to another user. Owner-only, atomic.
  static bool canTransferOwnership(UserRole role) => role == UserRole.owner;

  /// Read or change server-wide configuration (future surface, e.g.
  /// toggling signup). Deliberately owner-only; admins manage users and
  /// packages but not the host.
  static bool canManageServerSettings(UserRole role) => role == UserRole.owner;
}
