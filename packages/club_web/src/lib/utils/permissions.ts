/**
 * Client-side permission predicates for hiding buttons and nav items.
 *
 * These mirror the server's rules at a high level. They are **not** a
 * security boundary — the server re-checks every mutation. If a client
 * check disagrees with the server, the server wins. Keep these cheap
 * and conservative; prefer false negatives over false positives.
 */
import { roleIsAtLeast, type User } from '$lib/stores/auth';

/** Server admins can do anything that's admin-gated. */
export function isServerAdmin(user: User | null): boolean {
  return !!user && roleIsAtLeast(user.role, 'admin');
}

export function isOwner(user: User | null): boolean {
  return !!user && user.role === 'owner';
}

/**
 * Can the user perform package-admin actions on this package?
 * True when: server admin, OR an uploader of this package, OR an admin
 * member of the owning publisher.
 *
 * The caller passes the uploader list and publisher membership facts
 * from whatever API response they already have.
 */
export function canManagePackage(
  user: User | null,
  opts: {
    uploaderIds: string[];
    publisherId?: string | null;
    isPublisherAdmin?: boolean;
  }
): boolean {
  if (!user) return false;
  if (isServerAdmin(user)) return true;
  if (opts.uploaderIds.includes(user.id)) return true;
  if (opts.publisherId && opts.isPublisherAdmin) return true;
  return false;
}

/**
 * Can the user edit publisher details and manage members?
 * True when: server admin, OR a publisher admin.
 */
export function canManagePublisher(
  user: User | null,
  opts: { isPublisherAdmin?: boolean }
): boolean {
  if (!user) return false;
  if (isServerAdmin(user)) return true;
  return !!opts.isPublisherAdmin;
}

/**
 * Any authenticated non-viewer can attempt to verify a publisher by
 * proving DNS control. The verification itself does the gating; this
 * predicate only decides whether to show the "Create verified publisher"
 * entry point.
 */
export function canVerifyPublisher(user: User | null): boolean {
  if (!user) return false;
  return roleIsAtLeast(user.role, 'member');
}

/**
 * Internal (unverified, arbitrary-slug) publishers are admin-only,
 * because they bypass the DNS proof. Admins use this for teams that
 * don't have a public domain or for legacy/internal namespaces.
 */
export function canCreateInternalPublisher(user: User | null): boolean {
  return isServerAdmin(user);
}

/**
 * Legacy alias kept for existing call sites. Treats "can create a
 * publisher" as "can at least verify one".
 */
export function canCreatePublisher(user: User | null): boolean {
  return canVerifyPublisher(user);
}

/** Server ownership transfer is owner-only. */
export function canTransferServerOwnership(user: User | null): boolean {
  return isOwner(user);
}

/** Can the user see the Admin sidebar at all? */
export function canSeeAdminArea(user: User | null): boolean {
  return isServerAdmin(user);
}
