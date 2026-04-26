<script lang="ts">
  import { api } from '$lib/api/client';
  import ActivityLog, { type Entry } from '$lib/components/ActivityLog.svelte';

  let entries = $state<Entry[]>([]);
  let loading = $state(true);
  let hasMore = $state(false);

  $effect(() => {
    loadInitial();
  });

  async function loadInitial() {
    loading = true;
    try {
      const data = await api.get<{ entries: Entry[] }>(
        '/api/account/activity-log',
      );
      entries = data.entries ?? [];
      hasMore = entries.length >= 50;
    } catch {
      entries = [];
    } finally {
      loading = false;
    }
  }

  async function loadMore() {
    const last = entries[entries.length - 1];
    if (!last) return;
    loading = true;
    try {
      const data = await api.get<{ entries: Entry[] }>(
        `/api/account/activity-log?before=${encodeURIComponent(last.createdAt)}`,
      );
      const more = data.entries ?? [];
      entries = [...entries, ...more];
      hasMore = more.length >= 50;
    } finally {
      loading = false;
    }
  }
</script>

<svelte:head><title>Activity log | CLUB</title></svelte:head>

<!-- Root wrapper: root <main> is flex-row, so single child required. -->
<div class="page">
  <header class="page-header">
    <h1>Activity log</h1>
    <p>Events you've triggered — package publishes, uploader changes, publisher updates, and more.</p>
  </header>

  {#if !loading && entries.length === 0}
    <div class="empty-state">
      <div class="empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="10"/>
          <polyline points="12 6 12 12 16 14"/>
        </svg>
      </div>
      <h2>No activity yet</h2>
      <p>
        Your activity log records actions you take on the server — publishing a
        package version, adding an uploader, creating an API key, and so on.
      </p>
    </div>
  {:else}
    <!-- The ActivityLog component owns "loading / empty / list / load-more"
         rendering internally. `showAgent={false}` because on a user's own log
         the agent is always themselves — showing it would just be noise. -->
    <ActivityLog
      {entries}
      {loading}
      {hasMore}
      emptyMessage="No activity recorded yet."
      showAgent={false}
      onLoadMore={loadMore}
    />
  {/if}
</div>

<style>
  .page {
    width: 100%;
    min-width: 0;
  }

  .page-header {
    margin-bottom: 1.5rem;
  }

  .page-header h1 {
    margin: 0 0 0.25rem;
    font-size: 1.375rem;
    font-weight: 700;
  }

  .page-header p {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    max-width: 42rem;
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    padding: 3.5rem 1.5rem;
    border: 1px dashed var(--border);
    border-radius: 12px;
    background: var(--card);
    gap: 0.75rem;
  }

  .empty-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 64px;
    height: 64px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--primary) 10%, transparent);
    color: var(--primary);
    margin-bottom: 0.25rem;
  }

  .empty-state h2 {
    margin: 0;
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--foreground);
  }

  .empty-state p {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    max-width: 34rem;
    line-height: 1.55;
  }
</style>
