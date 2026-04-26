<script lang="ts">
  import { api } from '$lib/api/client';
  import PackageCard from '$lib/components/PackageCard.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { createDebouncedSignal } from '$lib/utils/debounce.svelte';

  interface MyPackage {
    name: string;
    publisherId?: string | null;
    latestVersion?: string | null;
    likesCount?: number;
    isDiscontinued?: boolean;
    isUnlisted?: boolean;
    updatedAt: string;
    description?: string;
    dartSdk?: string | null;
    flutterSdk?: string | null;
    repository?: string | null;
    homepage?: string | null;
  }

  const search = createDebouncedSignal();

  let packages = $state<MyPackage[]>([]);
  let totalCount = $state(0);
  let loading = $state(true);
  let nextPage = $state<string | null>(null);

  $effect(() => {
    const q = search.debounced;
    // Reset synchronously so a stale "Load more" click during the
    // in-flight fetch can't append previous-query results.
    packages = [];
    nextPage = null;
    loading = true;
    api
      .get<any>(`/api/account/packages${q ? `?q=${encodeURIComponent(q)}` : ''}`)
      .then((data) => {
        packages = data.packages ?? [];
        totalCount = data.totalCount ?? packages.length;
        nextPage = data.nextPageToken ?? null;
      })
      .catch(() => {
        packages = [];
        totalCount = 0;
        nextPage = null;
      })
      .finally(() => (loading = false));
  });

  async function loadMore() {
    if (!nextPage) return;
    loading = true;
    try {
      const qs = new URLSearchParams();
      if (search.debounced) qs.set('q', search.debounced);
      qs.set('page', nextPage);
      const data = await api.get<any>(`/api/account/packages?${qs.toString()}`);
      packages = [...packages, ...(data.packages ?? [])];
      nextPage = data.nextPageToken ?? null;
    } finally {
      loading = false;
    }
  }
</script>

<svelte:head><title>My packages | CLUB</title></svelte:head>

<!--
  Root wrapper so the global flex-row <main> treats this whole page as
  one child. Without it, the heading, filter, and list would spread out
  horizontally.
-->
<div class="page">
  <header class="page-header">
    <h1>My packages</h1>
    <p>Packages you can publish to — either as a direct uploader or as a member of the owning publisher.</p>
  </header>

  <div class="toolbar">
    <div class="search">
      <Input
        value={search.raw}
        oninput={(e) => search.set((e.currentTarget as HTMLInputElement).value)}
        placeholder="Filter by name..."
      />
    </div>
    {#if !loading && packages.length > 0}
      <span class="count">{totalCount} package{totalCount === 1 ? '' : 's'}</span>
    {/if}
  </div>

  {#if loading && packages.length === 0}
    <div class="empty-state">
      <p>Loading...</p>
    </div>
  {:else if packages.length === 0}
    <div class="empty-state">
      <div class="empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
          <polyline points="3.29 7.17 12 12 20.71 7.17"/>
          <line x1="12" y1="22" x2="12" y2="12"/>
        </svg>
      </div>
      <h2>
        {search.debounced ? 'No matches' : 'No packages yet'}
      </h2>
      <p>
        {#if search.debounced}
          No packages matching "{search.debounced}" — try a different filter.
        {:else}
          You don't own any packages yet. Publish your first package and it'll
          show up here, whether you own it directly or through a publisher.
        {/if}
      </p>
    </div>
  {:else}
    <div class="list">
      {#each packages as p (p.name)}
        <PackageCard
          package={{
            name: p.name,
            description: p.description,
            version: p.latestVersion ?? '0.0.0',
            publishedAt: p.updatedAt,
            likes: p.likesCount,
            dartSdk: p.dartSdk,
            flutterSdk: p.flutterSdk,
            repository: p.repository,
            homepage: p.homepage,
            isDiscontinued: p.isDiscontinued,
            isUnlisted: p.isUnlisted,
          }}
        />
      {/each}
    </div>
    {#if nextPage}
      <div class="more">
        <Button variant="outline" onclick={loadMore} disabled={loading}>
          {loading ? 'Loading...' : 'Load more'}
        </Button>
      </div>
    {/if}
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

  .toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem 1rem;
    margin-bottom: 1rem;
  }

  .search {
    flex: 1 1 14rem;
    min-width: 0;
    max-width: 22rem;
  }

  .count {
    color: var(--muted-foreground);
    font-size: 0.8125rem;
    white-space: nowrap;
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .more {
    display: flex;
    justify-content: center;
    padding: 1rem 0;
  }

  /* Shared centered empty state — matches the one on /my-publishers. */
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
