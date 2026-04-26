/**
 * Human-readable "time ago" formatter used by activity logs, package
 * lists, and anywhere we surface a past timestamp to the user.
 * Returns "today", "yesterday", "3 days ago", "5 months ago", "2 years
 * ago" — matches the tone of the surrounding UI without bringing in a
 * whole date library.
 */
export function timeAgo(dateStr: string | null | undefined): string {
  if (!dateStr) return '';
  const diff = Date.now() - new Date(dateStr).getTime();
  const days = Math.floor(diff / 86_400_000);
  if (days === 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days < 30) return `${days} days ago`;
  if (days < 365) return `${Math.floor(days / 30)} months ago`;
  return `${Math.floor(days / 365)} years ago`;
}

/** Locale date + time ("Apr 17, 2026, 2:34 PM"). */
export function formatDate(dateStr: string | null | undefined): string {
  if (!dateStr) return '';
  return new Date(dateStr).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}
