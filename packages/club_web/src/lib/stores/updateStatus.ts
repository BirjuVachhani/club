import { writable } from 'svelte/store';
import { browser } from '$app/environment';

export interface UpdateStatus {
  running: string;
  latest: string | null;
  updateAvailable: boolean;
  releaseUrl: string | null;
  releaseTag: string | null;
  releaseNotes: string | null;
  publishedAt: string | null;
  checkedAt: string | null;
}

/**
 * Latest server-side update snapshot. Hydrated from
 * `/api/admin/update-status` in the root layout load when the user is
 * an admin; stays `null` for non-admins (they never see the badge or
 * the dialog anyway).
 */
export const updateStatus = writable<UpdateStatus | null>(null);

// ── Dismissal persistence ─────────────────────────────────────
//
// The dialog is shown once per `latest` version. The admin can:
//   - Click OK            → never show this version's dialog again.
//   - Click Remind later  → show again after 24h.
//
// Both pieces of state live in localStorage so a single browser silos
// it. Dismissal is per-version: a brand-new release re-shows the
// dialog regardless of any previous dismissal.

const DISMISSED_KEY = 'club_update_dismissed_v';
const REMIND_AT_KEY = 'club_update_remind_at';
const REMIND_LATER_MS = 24 * 60 * 60 * 1000;

/** Persistently dismiss the given version — clicked OK in the dialog. */
export function dismissVersion(version: string): void {
  if (!browser) return;
  try {
    localStorage.setItem(DISMISSED_KEY, version);
    localStorage.removeItem(REMIND_AT_KEY);
  } catch {
    // localStorage can throw in private mode / quota-exceeded. The
    // only consequence is the admin sees the dialog again next page;
    // not worth a UI error for.
  }
}

/** Snooze the dialog for 24 hours. Independent of the per-version
 * dismissal, so a new release between now and the snooze expiry will
 * still re-prompt immediately. */
export function remindLater(): void {
  if (!browser) return;
  try {
    localStorage.setItem(REMIND_AT_KEY, String(Date.now() + REMIND_LATER_MS));
  } catch {
    // See dismissVersion for why we silently swallow.
  }
}

/** True iff the dialog should be displayed for [version] right now. */
export function shouldShowDialog(version: string): boolean {
  if (!browser) return false;
  try {
    if (localStorage.getItem(DISMISSED_KEY) === version) return false;
    const remindAt = localStorage.getItem(REMIND_AT_KEY);
    if (remindAt) {
      const ts = Number.parseInt(remindAt, 10);
      if (Number.isFinite(ts) && Date.now() < ts) return false;
    }
    return true;
  } catch {
    // If localStorage is unavailable we err on the side of showing
    // the dialog — better to nag once than to silently hide a
    // security-relevant update notification.
    return true;
  }
}
