<script lang="ts">
  import { page } from '$app/state';
  import { api } from '$lib/api/client';
  import ActivityLog, { type Entry } from '$lib/components/ActivityLog.svelte';

  const id = $derived(page.params.id);

  let entries = $state<Entry[]>([]);
  let loading = $state(true);
  let hasMore = $state(false);

  $effect(() => {
    const current = id;
    loading = true;
    entries = [];
    hasMore = false;

    api
      .get<{ entries: Entry[] }>(`/api/publishers/${current}/activity-log`)
      .then((data) => {
        const list = data.entries ?? [];
        entries = list;
        hasMore = list.length >= 50;
      })
      .catch(() => {
        entries = [];
        hasMore = false;
      })
      .finally(() => (loading = false));
  });

  async function loadMore() {
    const last = entries[entries.length - 1];
    if (!last) return;
    loading = true;
    try {
      const data = await api.get<{ entries: Entry[] }>(
        `/api/publishers/${id}/activity-log?before=${encodeURIComponent(last.createdAt)}`,
      );
      const more = data.entries ?? [];
      entries = [...entries, ...more];
      hasMore = more.length >= 50;
    } finally {
      loading = false;
    }
  }
</script>

<p class="intro">Events related to this publisher, newest first.</p>

<ActivityLog
  {entries}
  {loading}
  {hasMore}
  emptyMessage="No activity recorded for this publisher."
  onLoadMore={loadMore}
/>

<style>
  .intro {
    margin: 0 0 1rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
  }
</style>
