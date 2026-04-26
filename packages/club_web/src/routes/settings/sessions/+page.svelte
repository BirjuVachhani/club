<script lang="ts">
  import Alert from '$lib/components/ui/Alert.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Card from '$lib/components/ui/Card.svelte';
  import { api, ApiError } from '$lib/api/client';
  import { parseUserAgent, type ParsedUserAgent } from '$lib/utils/userAgent';
  import { formatLocation } from '$lib/utils/geolocation';
  import { timeAgo, formatDate } from '$lib/utils/date';
  import { confirmDialog } from '$lib/stores/confirm';
  import { onMount } from 'svelte';

  interface Session {
    id: string;
    userAgent: string | null;
    clientIp: string | null;
    clientCity: string | null;
    clientRegion: string | null;
    clientCountry: string | null;
    clientCountryCode: string | null;
    createdAt: string;
    expiresAt: string | null;
    absoluteExpiresAt: string | null;
    lastUsedAt: string | null;
    current: boolean;
  }

  interface EnrichedSession extends Session {
    parsed: ParsedUserAgent;
    /** Pre-formatted display string built from the server-provided fields. */
    locationLabel: string;
    /** Count of other sessions that share the same browser/OS/device. */
    siblingCount: number;
  }

  let sessions = $state<EnrichedSession[]>([]);
  let loading = $state(true);
  let working = $state(false);
  let error = $state('');

  const otherActive = $derived(sessions.filter((s) => !s.current).length);

  // Sort: current first, then most recently active.
  const sorted = $derived(
    [...sessions].sort((a, b) => {
      if (a.current !== b.current) return a.current ? -1 : 1;
      const aT = a.lastUsedAt ? new Date(a.lastUsedAt).getTime() : 0;
      const bT = b.lastUsedAt ? new Date(b.lastUsedAt).getTime() : 0;
      return bT - aT;
    }),
  );

  onMount(async () => {
    await load();
  });

  async function load() {
    loading = true;
    error = '';
    try {
      const data = await api.get<{ sessions: Session[] }>('/api/auth/sessions');
      const raw = data.sessions ?? [];

      const sigCount = new Map<string, number>();
      for (const s of raw) {
        const sig = parseUserAgent(s.userAgent).signature;
        sigCount.set(sig, (sigCount.get(sig) ?? 0) + 1);
      }

      sessions = raw.map((s) => {
        const parsed = parseUserAgent(s.userAgent);
        return {
          ...s,
          parsed,
          locationLabel: formatLocation({
            city: s.clientCity,
            country: s.clientCountry,
            countryCode: s.clientCountryCode,
            ip: s.clientIp,
          }),
          siblingCount: (sigCount.get(parsed.signature) ?? 1) - 1,
        };
      });
    } catch {
      error = 'Failed to load sessions.';
    } finally {
      loading = false;
    }
  }

  async function revoke(session: EnrichedSession) {
    const description = session.current
      ? 'You will need to sign in again.'
      : `${session.parsed.label} will lose access immediately.`;
    const ok = await confirmDialog({
      title: session.current ? 'Sign out of this device?' : 'Sign out this session?',
      description,
      confirmLabel: 'Sign out',
      confirmVariant: 'destructive'
    });
    if (!ok) return;

    working = true;
    try {
      await api.delete(`/api/auth/sessions/${session.id}`);
      if (session.current) {
        window.location.href = '/login';
        return;
      }
      sessions = sessions.filter((s) => s.id !== session.id);
    } catch (e) {
      error = e instanceof ApiError ? `Failed (${e.status}).` : 'Failed to revoke session.';
    } finally {
      working = false;
    }
  }

  async function revokeOthers() {
    const ok = await confirmDialog({
      title: 'Sign out every other device?',
      description: "This can't be undone.",
      confirmLabel: 'Sign out others',
      confirmVariant: 'destructive'
    });
    if (!ok) return;

    working = true;
    try {
      await api.post('/api/auth/sessions/revoke-others');
      sessions = sessions.filter((s) => s.current);
    } catch {
      error = 'Failed to sign out other sessions.';
    } finally {
      working = false;
    }
  }

  function lastActiveText(session: EnrichedSession): string {
    if (session.current) return 'Active now';
    const iso = session.lastUsedAt ?? session.createdAt;
    if (!iso) return 'Unknown';
    const diff = Date.now() - new Date(iso).getTime();
    if (diff < 60_000) return 'Active moments ago';
    if (diff < 3_600_000) {
      const mins = Math.floor(diff / 60_000);
      return `Active ${mins} minute${mins === 1 ? '' : 's'} ago`;
    }
    if (diff < 86_400_000) {
      const hrs = Math.floor(diff / 3_600_000);
      return `Active ${hrs} hour${hrs === 1 ? '' : 's'} ago`;
    }
    return `Last active ${timeAgo(iso)}`;
  }
</script>

<div class="space-y-6">
  <div>
    <h2 class="mb-1 text-2xl font-semibold tracking-tight">Your devices</h2>
    <p class="m-0 text-sm text-[var(--muted-foreground)]">
      Devices where you're signed in to club. Sessions extend up to 30 days of
      inactivity and hard-expire after 90 days regardless of use.
    </p>
  </div>

  {#if error}
    <Alert class="border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_10%,var(--card))] text-[var(--destructive)]">
      {error}
    </Alert>
  {/if}

  <Card class="p-6">
    <div class="mb-5 flex flex-wrap items-start justify-between gap-3">
      <div>
        <h3 class="mb-1 text-lg font-semibold">Active sessions</h3>
        <p class="m-0 text-sm text-[var(--muted-foreground)]">
          {#if loading}
            Loading…
          {:else if sessions.length === 0}
            No active sessions.
          {:else}
            {sessions.length} {sessions.length === 1 ? 'session' : 'sessions'}
            {#if otherActive > 0}
              · {otherActive} other {otherActive === 1 ? 'device' : 'devices'}
            {/if}
          {/if}
        </p>
      </div>
      {#if otherActive > 0}
        <Button variant="outline" disabled={working} onclick={revokeOthers}>
          Sign out all other sessions
        </Button>
      {/if}
    </div>

    {#if loading}
      <div class="py-6 text-center text-sm italic text-[var(--muted-foreground)]">
        Loading sessions…
      </div>
    {:else if sessions.length === 0}
      <div class="py-6 text-center text-sm italic text-[var(--muted-foreground)]">
        No active sessions.
      </div>
    {:else}
      <ul class="session-list">
        {#each sorted as s (s.id)}
          <li class="session-row" class:current={s.current}>
            <div class="device-icon" class:current-icon={s.current}>
              {#if s.parsed.deviceType === 'mobile'}
                <!-- Smartphone -->
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <rect x="5" y="2" width="14" height="20" rx="2" ry="2" />
                  <line x1="12" y1="18" x2="12.01" y2="18" />
                </svg>
              {:else if s.parsed.deviceType === 'tablet'}
                <!-- Tablet -->
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <rect x="4" y="2" width="16" height="20" rx="2" ry="2" />
                  <line x1="12" y1="18" x2="12.01" y2="18" />
                </svg>
              {:else}
                <!-- Monitor / desktop -->
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
                  <line x1="8" y1="21" x2="16" y2="21" />
                  <line x1="12" y1="17" x2="12" y2="21" />
                </svg>
              {/if}
            </div>

            <div class="session-main">
              <div class="session-title-row">
                <span class="device-name">{s.parsed.label}</span>
                {#if s.current}
                  <span class="badge badge-current">
                    <span class="dot"></span>
                    This device
                  </span>
                {/if}
                {#if s.siblingCount > 0 && !s.current}
                  <span class="badge badge-muted" title="You have other sessions on the same browser/OS.">
                    +{s.siblingCount} more on this device
                  </span>
                {/if}
              </div>

              <div class="session-meta">
                <span class="meta-item">
                  <!-- map-pin -->
                  <svg class="meta-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    <path d="M20 10c0 7-8 13-8 13s-8-6-8-13a8 8 0 0 1 16 0z" />
                    <circle cx="12" cy="10" r="3" />
                  </svg>
                  {s.locationLabel}
                  {#if s.clientIp}
                    <span class="ip-chip">{s.clientIp}</span>
                  {/if}
                </span>
                <span class="meta-item">
                  <!-- clock -->
                  <svg class="meta-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    <circle cx="12" cy="12" r="10" />
                    <polyline points="12 6 12 12 16 14" />
                  </svg>
                  {lastActiveText(s)}
                </span>
                <span class="meta-item muted">
                  Signed in {formatDate(s.createdAt)}
                </span>
              </div>
            </div>

            <div class="session-actions">
              <button
                class="revoke-btn"
                type="button"
                disabled={working}
                onclick={() => revoke(s)}
                aria-label={s.current ? 'Sign out of this device' : 'Sign out'}
              >
                <!-- log-out -->
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                  <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                  <polyline points="16 17 21 12 16 7" />
                  <line x1="21" y1="12" x2="9" y2="12" />
                </svg>
                <span>{s.current ? 'Sign out' : 'Revoke'}</span>
              </button>
            </div>
          </li>
        {/each}
      </ul>
    {/if}
  </Card>
</div>

<style>
  .session-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
    list-style: none;
    padding: 0;
    margin: 0;
  }

  .session-row {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 16px;
    padding: 16px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--card);
    transition: border-color 120ms ease, background 120ms ease;
  }

  .session-row:hover {
    border-color: color-mix(in srgb, var(--foreground) 18%, var(--border));
  }

  .session-row.current {
    border-color: color-mix(in srgb, var(--pub-success-color) 40%, var(--border));
    background: color-mix(in srgb, var(--pub-success-color) 4%, var(--card));
  }

  .device-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 44px;
    height: 44px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--foreground) 6%, transparent);
    color: var(--foreground);
    flex-shrink: 0;
  }

  .device-icon.current-icon {
    background: color-mix(in srgb, var(--pub-success-color) 14%, transparent);
    color: var(--pub-success-color);
  }

  .device-icon svg {
    width: 22px;
    height: 22px;
  }

  .session-main {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .session-title-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .device-name {
    font-weight: 600;
    font-size: 14.5px;
    color: var(--foreground);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 999px;
    line-height: 1.4;
    white-space: nowrap;
  }

  .badge-current {
    background: color-mix(in srgb, var(--pub-success-color) 15%, transparent);
    color: var(--pub-success-color);
  }

  .badge-current .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--pub-success-color);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--pub-success-color) 25%, transparent);
  }

  .badge-muted {
    background: color-mix(in srgb, var(--foreground) 8%, transparent);
    color: var(--muted-foreground);
  }

  .session-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 4px 14px;
    font-size: 12.5px;
    color: var(--muted-foreground);
  }

  .meta-item {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }

  .meta-item.muted {
    opacity: 0.75;
  }

  .meta-icon {
    width: 13px;
    height: 13px;
    flex-shrink: 0;
  }

  .ip-chip {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 11px;
    padding: 1px 6px;
    border-radius: 4px;
    background: color-mix(in srgb, var(--foreground) 6%, transparent);
    color: var(--muted-foreground);
    margin-left: 4px;
  }

  .session-actions {
    display: flex;
    align-items: center;
  }

  .revoke-btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px;
    border: 1px solid color-mix(in srgb, var(--destructive) 35%, var(--border));
    border-radius: 8px;
    background: transparent;
    color: var(--destructive);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 120ms ease, border-color 120ms ease;
  }

  .revoke-btn svg {
    width: 14px;
    height: 14px;
  }

  .revoke-btn:hover:not(:disabled) {
    background: color-mix(in srgb, var(--destructive) 10%, transparent);
    border-color: var(--destructive);
  }

  .revoke-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  @media (max-width: 640px) {
    .session-row {
      grid-template-columns: auto 1fr;
      grid-template-areas:
        'icon main'
        'actions actions';
      row-gap: 12px;
    }

    .device-icon {
      grid-area: icon;
    }

    .session-main {
      grid-area: main;
    }

    .session-actions {
      grid-area: actions;
      justify-content: flex-end;
    }
  }
</style>
