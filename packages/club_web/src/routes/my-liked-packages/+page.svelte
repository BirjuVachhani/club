<script lang="ts">
  import { api } from '$lib/api/client';

  let liked = $state<string[]>([]);
  let loading = $state(true);

  $effect(() => {
    api
      .get<any>('/api/account/likes')
      .then((data) => {
        liked = (data.likedPackages ?? []).map((l: any) => l.package);
      })
      .catch(() => (liked = []))
      .finally(() => (loading = false));
  });

  async function unlike(name: string) {
    try {
      await api.delete(`/api/account/likes/${encodeURIComponent(name)}`);
      liked = liked.filter((n) => n !== name);
    } catch {
      // Leave list as-is; next reload will reconcile.
    }
  }
</script>

<svelte:head><title>Liked packages | CLUB</title></svelte:head>

<!-- Root wrapper: root <main> is flex-row, so single child required. -->
<div class="page">
  <header class="page-header">
    <h1>Liked packages</h1>
    <p>Packages you've liked. Click the heart on any package page to add or remove a like.</p>
  </header>

  {#if loading}
    <div class="empty-state">
      <p>Loading...</p>
    </div>
  {:else if liked.length === 0}
    <div class="empty-state">
      <div class="empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>
        </svg>
      </div>
      <h2>No liked packages yet</h2>
      <p>
        Find packages you use often and tap the heart on their detail page —
        they'll show up here so you can jump back to them.
      </p>
      <a href="/packages" class="browse-link">Browse packages →</a>
    </div>
  {:else}
    <ul class="list">
      {#each liked as name (name)}
        <li class="row">
          <a href={`/packages/${name}`} class="pkg-name">{name}</a>
          <button onclick={() => unlike(name)} class="unlike" title="Unlike" aria-label={`Unlike ${name}`}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <line x1="18" y1="6" x2="6" y2="18"/>
              <line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
        </li>
      {/each}
    </ul>
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

  .list {
    list-style: none;
    padding: 0;
    margin: 0;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    overflow: hidden;
  }

  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid var(--border);
    transition: background 0.12s;
  }

  .row:last-child {
    border-bottom: none;
  }

  .row:hover {
    background: var(--accent);
  }

  .pkg-name {
    color: var(--primary);
    text-decoration: none;
    font-size: 0.9375rem;
    font-weight: 500;
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .pkg-name:hover {
    text-decoration: underline;
  }

  .unlike {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: var(--muted-foreground);
    cursor: pointer;
    transition: color 0.12s, background 0.12s;
  }

  .unlike:hover {
    color: var(--destructive);
    background: color-mix(in srgb, var(--destructive) 10%, transparent);
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

  .browse-link {
    margin-top: 0.5rem;
    color: var(--primary);
    text-decoration: none;
    font-size: 0.875rem;
    font-weight: 500;
  }

  .browse-link:hover {
    text-decoration: underline;
  }
</style>
