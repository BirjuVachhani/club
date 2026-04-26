<script lang="ts">
  import { api, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { createDebouncedSignal } from '$lib/utils/debounce.svelte';
  import { confirmDialog } from '$lib/stores/confirm';

  interface AdminPkg {
    name: string;
    publisherId: string | null;
    latestVersion: string | null;
    versionCount: number;
    totalBytes: number;
    likesCount: number;
    isDiscontinued: boolean;
    isUnlisted: boolean;
    updatedAt: string;
  }

  const search = createDebouncedSignal();

  let packages = $state<AdminPkg[]>([]);
  let totalCount = $state(0);
  let nextPage = $state<string | null>(null);
  let loading = $state(true);
  let message = $state('');
  let tone: 'info' | 'error' | 'success' = $state('info');

  // Expanded row — for showing per-version delete actions.
  let expanded = $state<string | null>(null);
  let versionsFor = $state<Record<string, any[]>>({});
  let versionsLoading = $state<Record<string, boolean>>({});

  $effect(() => {
    const q = search.debounced;
    // Reset synchronously so a stale "Load more" click during the
    // in-flight fetch can't append previous-query results.
    packages = [];
    nextPage = null;
    loading = true;
    load(q);
  });

  async function load(q: string, page?: string) {
    try {
      const qs = new URLSearchParams();
      if (q) qs.set('q', q);
      if (page) qs.set('page', page);
      const data = await api.get<any>(
        `/api/admin/packages${qs.toString() ? `?${qs}` : ''}`,
      );
      if (page) {
        packages = [...packages, ...(data.packages ?? [])];
      } else {
        packages = data.packages ?? [];
      }
      totalCount = data.totalCount ?? packages.length;
      nextPage = data.nextPageToken ?? null;
    } catch {
      setMsg('Failed to load packages.', 'error');
    } finally {
      loading = false;
    }
  }

  async function loadMore() {
    if (!nextPage) return;
    loading = true;
    await load(search.debounced, nextPage);
  }

  function setMsg(text: string, t: typeof tone = 'info') {
    message = text;
    tone = t;
  }

  async function deletePackage(name: string) {
    const ok = await confirmDialog({
      title: `Delete package "${name}"?`,
      description: 'This removes the package and ALL of its versions. This cannot be undone.',
      confirmLabel: 'Delete',
      confirmVariant: 'destructive',
      confirmText: name
    });
    if (!ok) return;
    try {
      await api.delete(`/api/admin/packages/${name}`);
      setMsg(`Package ${name} deleted.`, 'success');
      packages = packages.filter((p) => p.name !== name);
      totalCount -= 1;
    } catch (err) {
      setMsg(apiErrorMessage(err, 'Failed to delete package.'), 'error');
    }
  }

  async function toggleExpanded(name: string) {
    if (expanded === name) {
      expanded = null;
      return;
    }
    expanded = name;
    if (!versionsFor[name]) {
      versionsLoading = { ...versionsLoading, [name]: true };
      try {
        const data = await api.get<any>(`/api/packages/${name}`);
        versionsFor = { ...versionsFor, [name]: data.versions ?? [] };
      } catch {
        versionsFor = { ...versionsFor, [name]: [] };
      } finally {
        versionsLoading = { ...versionsLoading, [name]: false };
      }
    }
  }

  async function deleteVersion(name: string, version: string) {
    const ok = await confirmDialog({
      title: `Delete ${name} ${version}?`,
      description: 'This cannot be undone.',
      confirmLabel: 'Delete',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    try {
      await api.delete(
        `/api/admin/packages/${name}/versions/${encodeURIComponent(version)}`,
      );
      setMsg(`Deleted ${name} ${version}.`, 'success');
      versionsFor = {
        ...versionsFor,
        [name]: (versionsFor[name] ?? []).filter((v) => v.version !== version),
      };
    } catch (err) {
      setMsg(apiErrorMessage(err, 'Failed to delete version.'), 'error');
    }
  }

  function formatBytes(n: number): string {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
    return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  function timeAgo(dateStr: string): string {
    const diff = Date.now() - new Date(dateStr).getTime();
    const days = Math.floor(diff / 86400000);
    if (days === 0) return 'today';
    if (days < 30) return `${days}d ago`;
    if (days < 365) return `${Math.floor(days / 30)}mo ago`;
    return `${Math.floor(days / 365)}y ago`;
  }
</script>

<svelte:head><title>Packages | Admin | CLUB</title></svelte:head>

<h1 class="title">Packages</h1>
<p class="sub">Every package on this server. Expand a row to manage individual versions.</p>

<div class="search">
  <Input
    value={search.raw}
    oninput={(e) => search.set((e.currentTarget as HTMLInputElement).value)}
    placeholder="Filter by name..."
  />
</div>

<InlineMessage {message} {tone} />

{#if loading && packages.length === 0}
  <p class="empty">Loading...</p>
{:else if packages.length === 0}
  <p class="empty">No packages match.</p>
{:else}
  <div class="table-scroll">
  <table class="pkg-table">
    <thead>
      <tr>
        <th></th>
        <th>Package</th>
        <th>Latest</th>
        <th>Versions</th>
        <th>Size</th>
        <th>Updated</th>
        <th>Owner</th>
        <th class="col-actions"></th>
      </tr>
    </thead>
    <tbody>
      {#each packages as p (p.name)}
        <tr class:expanded={expanded === p.name}>
          <td class="col-toggle">
            <button class="disclosure" onclick={() => toggleExpanded(p.name)} aria-label="Show versions">
              {expanded === p.name ? '▾' : '▸'}
            </button>
          </td>
          <td>
            <a href={`/packages/${p.name}`} class="pkg-link">{p.name}</a>
            {#if p.isDiscontinued}<span class="flag">discontinued</span>{/if}
            {#if p.isUnlisted}<span class="flag">unlisted</span>{/if}
          </td>
          <td class="mono">{p.latestVersion ?? '—'}</td>
          <td>{p.versionCount}</td>
          <td>{formatBytes(p.totalBytes)}</td>
          <td>{timeAgo(p.updatedAt)}</td>
          <td>
            {#if p.publisherId}
              <a href={`/publishers/${p.publisherId}`} class="pub-link">{p.publisherId}</a>
            {:else}
              <span class="muted">uploaders</span>
            {/if}
          </td>
          <td class="col-actions">
            <button class="danger" onclick={() => deletePackage(p.name)} title="Delete package">Delete</button>
          </td>
        </tr>
        {#if expanded === p.name}
          <tr class="version-rows">
            <td></td>
            <td colspan="7">
              {#if versionsLoading[p.name]}
                <p class="v-loading">Loading versions...</p>
              {:else if (versionsFor[p.name] ?? []).length === 0}
                <p class="v-loading">No versions.</p>
              {:else}
                <table class="v-table">
                  <thead>
                    <tr><th>Version</th><th>Published</th><th></th></tr>
                  </thead>
                  <tbody>
                    {#each versionsFor[p.name] ?? [] as v (v.version)}
                      <tr>
                        <td class="mono">{v.version}</td>
                        <td>{v.publishedAt ? new Date(v.publishedAt).toLocaleString() : '—'}</td>
                        <td class="col-actions">
                          <button class="danger small" onclick={() => deleteVersion(p.name, v.version)}>Delete version</button>
                        </td>
                      </tr>
                    {/each}
                  </tbody>
                </table>
              {/if}
            </td>
          </tr>
        {/if}
      {/each}
    </tbody>
  </table>
  </div>

  <p class="count">
    Showing {packages.length} of {totalCount} package{totalCount === 1 ? '' : 's'}
  </p>

  {#if nextPage}
    <div class="more">
      <Button variant="outline" onclick={loadMore} disabled={loading}>
        {loading ? 'Loading...' : 'Load more'}
      </Button>
    </div>
  {/if}
{/if}

<style>
  .title {
    font-size: 1.375rem;
    font-weight: 700;
    margin: 0 0 0.25rem;
  }
  .sub {
    margin: 0 0 1.25rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
  }
  .search {
    margin-bottom: 1rem;
    width: 100%;
    max-width: 20rem;
  }
  .table-scroll {
    width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    margin: 0 -0.5rem;
    padding: 0 0.5rem;
  }
  .pkg-table {
    width: 100%;
    min-width: 720px;
    border-collapse: collapse;
    font-size: 0.875rem;
  }
  .pkg-table th {
    text-align: left;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--muted-foreground);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.6rem 0.5rem;
    border-bottom: 2px solid var(--border);
  }
  .pkg-table td {
    padding: 0.65rem 0.5rem;
    border-bottom: 1px solid var(--border);
    vertical-align: middle;
  }
  .col-toggle { width: 28px; }
  .col-actions { text-align: right; }
  .disclosure {
    background: none;
    border: none;
    color: var(--muted-foreground);
    cursor: pointer;
    font-size: 0.875rem;
    padding: 0 0.25rem;
  }
  .disclosure:hover {
    color: var(--foreground);
  }
  .pkg-link {
    color: var(--primary);
    text-decoration: none;
    font-weight: 500;
  }
  .pkg-link:hover {
    text-decoration: underline;
  }
  .pub-link {
    color: var(--primary);
    text-decoration: none;
  }
  .pub-link:hover {
    text-decoration: underline;
  }
  .mono {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }
  .muted {
    color: var(--muted-foreground);
    font-size: 0.8125rem;
  }
  .flag {
    display: inline-block;
    margin-left: 0.4rem;
    padding: 0.1rem 0.3rem;
    border-radius: 3px;
    font-size: 0.65rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    background: var(--muted);
    color: var(--muted-foreground);
  }
  .danger {
    background: var(--destructive);
    color: var(--destructive-foreground);
    border: none;
    padding: 0.3rem 0.65rem;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.8125rem;
  }
  .danger:hover {
    filter: brightness(1.05);
  }
  .danger.small {
    padding: 0.2rem 0.5rem;
    font-size: 0.75rem;
  }
  tr.version-rows > td {
    background: color-mix(in srgb, var(--muted) 50%, var(--card));
    padding: 0.5rem 1rem;
  }
  .v-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.8125rem;
  }
  .v-table th {
    text-align: left;
    font-size: 0.7rem;
    font-weight: 600;
    color: var(--muted-foreground);
    padding: 0.4rem 0.5rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .v-table td {
    padding: 0.5rem;
    border-bottom: 1px solid var(--border);
  }
  .v-loading {
    padding: 0.5rem;
    color: var(--muted-foreground);
  }
  .count {
    margin: 1rem 0 0;
    color: var(--muted-foreground);
    font-size: 0.8125rem;
  }
  .more {
    display: flex;
    justify-content: center;
    padding: 1rem 0;
  }
  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
