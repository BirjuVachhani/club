<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import Button from '$lib/components/ui/Button.svelte';
  import PackageCard from '$lib/components/PackageCard.svelte';
  import type { PackageListItem } from './+page';

  let { data } = $props();

  const PLATFORMS = ['android', 'ios', 'linux', 'macos', 'web', 'windows'] as const;
  const SDKS = ['dart', 'flutter'] as const;

  function parseCsvParam(name: string, allowed: readonly string[]): Record<string, boolean> {
    const raw = page.url.searchParams.get(name) ?? '';
    const selected = new Set(raw.split(',').map((s) => s.trim()).filter(Boolean));
    return Object.fromEntries(allowed.map((k) => [k, selected.has(k)]));
  }

  let sortBy = $state('relevance');
  let filterPlatforms = $state<Record<string, boolean>>({
    android: false, ios: false, linux: false, macos: false, web: false, windows: false,
  });
  let filterSdks = $state<Record<string, boolean>>({ dart: false, flutter: false });
  let filtersOpen = $state(false);

  $effect(() => {
    sortBy = data.sort ?? 'relevance';
  });

  // Re-hydrate filter state from URL (initial mount + back/forward nav).
  $effect(() => {
    filterPlatforms = parseCsvParam('platforms', PLATFORMS);
    filterSdks = parseCsvParam('sdks', SDKS);
  });

  function buildUrl(overrides: { page?: number; sort?: string } = {}): string {
    const params = new URLSearchParams();
    const q = data.query ?? '';
    if (q) params.set('q', q);
    params.set('sort', overrides.sort ?? sortBy);
    params.set('page', String(overrides.page ?? data.page ?? 1));
    const plats = PLATFORMS.filter((p) => filterPlatforms[p]);
    if (plats.length > 0) params.set('platforms', plats.join(','));
    const sdks = SDKS.filter((s) => filterSdks[s]);
    if (sdks.length > 0) params.set('sdks', sdks.join(','));
    return `/packages?${params.toString()}`;
  }

  function handleSortChange() {
    goto(buildUrl({ sort: sortBy, page: 1 }));
  }

  function goToPage(p: number) {
    goto(buildUrl({ page: p }));
  }

  // Write filter state into the URL without re-running load — filtering is
  // client-side, so reloading would just refetch the same server results.
  function syncFilterUrl() {
    if (typeof window === 'undefined') return;
    window.history.replaceState(window.history.state, '', buildUrl());
  }

  let hasActiveFilters = $derived(
    Object.values(filterPlatforms).some(Boolean) || Object.values(filterSdks).some(Boolean)
  );

  function pkgMatchesPlatforms(pkg: PackageListItem, selected: string[]): boolean {
    if (selected.length === 0) return true;
    const tags = Array.isArray(pkg.tags) ? pkg.tags : [];
    return selected.some((p) => tags.includes(`platform:${p}`));
  }

  function pkgMatchesSdks(pkg: PackageListItem, selected: string[]): boolean {
    if (selected.length === 0) return true;
    const tags = Array.isArray(pkg.tags) ? pkg.tags : [];
    return selected.some((sdk) => {
      if (tags.includes(`sdk:${sdk}`)) return true;
      // Fallback for unscored packages (no tags derived yet): use pubspec env.
      if (tags.length === 0) {
        if (sdk === 'flutter') return !!pkg.flutterSdk;
        if (sdk === 'dart') return !!pkg.dartSdk && !pkg.flutterSdk;
      }
      return false;
    });
  }

  let filteredPackages = $derived.by((): PackageListItem[] => {
    const list = (data.packages ?? []) as PackageListItem[];
    if (!hasActiveFilters) return list;
    const selectedPlatforms = PLATFORMS.filter((p) => filterPlatforms[p]);
    const selectedSdks = SDKS.filter((s) => filterSdks[s]);
    return list.filter(
      (pkg) =>
        pkgMatchesPlatforms(pkg, selectedPlatforms) &&
        pkgMatchesSdks(pkg, selectedSdks),
    );
  });

  function onFilterChange() {
    syncFilterUrl();
  }

  function clearFilters() {
    filterPlatforms = Object.fromEntries(PLATFORMS.map((p) => [p, false]));
    filterSdks = Object.fromEntries(SDKS.map((s) => [s, false]));
    syncFilterUrl();
  }

  let totalPages = $derived(
    Math.max(1, Math.ceil((data.totalCount ?? 0) / (data.pageSize ?? 20)))
  );
</script>

<div class="packages-layout">
  <!-- Mobile filter toggle — only visible below 900px -->
  <button
    type="button"
    class="filters-toggle"
    onclick={() => (filtersOpen = !filtersOpen)}
    aria-expanded={filtersOpen}
    aria-controls="packages-filters"
  >
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <line x1="4" x2="20" y1="6" y2="6"/><line x1="6" x2="18" y1="12" y2="12"/><line x1="8" x2="16" y1="18" y2="18"/>
    </svg>
    Filters{hasActiveFilters ? ` · ${Object.values(filterPlatforms).filter(Boolean).length + Object.values(filterSdks).filter(Boolean).length}` : ''}
  </button>

  <!-- Sidebar -->
  <aside id="packages-filters" class="packages-sidebar" class:open={filtersOpen}>
    <div class="filter-section">
      <h4 class="filter-title">Platforms</h4>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.android} onchange={onFilterChange} />
        <span>Android</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.ios} onchange={onFilterChange} />
        <span>iOS</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.linux} onchange={onFilterChange} />
        <span>Linux</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.macos} onchange={onFilterChange} />
        <span>macOS</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.web} onchange={onFilterChange} />
        <span>Web</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterPlatforms.windows} onchange={onFilterChange} />
        <span>Windows</span>
      </label>
    </div>

    <div class="filter-section">
      <h4 class="filter-title">SDKs</h4>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterSdks.dart} onchange={onFilterChange} />
        <span>Dart</span>
      </label>
      <label class="filter-checkbox">
        <input type="checkbox" bind:checked={filterSdks.flutter} onchange={onFilterChange} />
        <span>Flutter</span>
      </label>
    </div>

    {#if hasActiveFilters}
      <button class="clear-filters" onclick={clearFilters}>Clear filters</button>
    {/if}
  </aside>

  <!-- Main content -->
  <div class="packages-main">
    <div class="packages-toolbar">
      <span class="results-count">
        <strong>RESULTS</strong>
        {#if hasActiveFilters}
          <span>{filteredPackages.length}</span>
          <span class="results-subtle">of {data.totalCount ?? 0} on this page</span>
        {:else}
          <span>{data.totalCount ?? 0}</span>
          packages
        {/if}
      </span>
      <div class="sort-control">
        <span>SORT BY</span>
        <select
          id="sort-select"
          bind:value={sortBy}
          onchange={handleSortChange}
        >
          <option value="relevance">DEFAULT RANKING</option>
          <option value="updated">RECENTLY UPDATED</option>
          <option value="likes">MOST LIKES</option>
        </select>
      </div>
    </div>

    <div class="packages-list">
      {#if filteredPackages.length > 0}
        {#each filteredPackages as pkg}
          <PackageCard {pkg} />
        {/each}
      {:else}
        <div class="empty-state">
          <p>No packages found.</p>
        </div>
      {/if}
    </div>

    {#if totalPages > 1}
      <nav class="pagination">
        <Button
          variant="outline"
          disabled={data.page <= 1}
          onclick={() => goToPage(data.page - 1)}
        >
          Previous
        </Button>
        <span class="page-info">Page {data.page} of {totalPages}</span>
        <Button
          variant="outline"
          disabled={data.page >= totalPages}
          onclick={() => goToPage(data.page + 1)}
        >
          Next
        </Button>
      </nav>
    {/if}
  </div>
</div>

<style>
  .packages-layout {
    display: grid;
    grid-template-columns: 1fr;
    gap: 16px;
    width: 100%;
  }

  @media (min-width: 900px) {
    .packages-layout {
      grid-template-columns: 180px minmax(0, 1fr);
      gap: 32px;
    }
  }

  .filters-toggle {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    width: fit-content;
    padding: 8px 14px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--card);
    color: var(--foreground);
    font-family: inherit;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }
  .filters-toggle:hover { background: var(--accent); }
  @media (min-width: 900px) {
    .filters-toggle { display: none; }
  }

  /* Sidebar */
  .packages-sidebar {
    font-size: 13px;
    display: none;
    padding: 12px 14px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
  }
  .packages-sidebar.open { display: block; }

  @media (min-width: 900px) {
    .packages-sidebar {
      display: block;
      position: sticky;
      top: 80px;
      align-self: start;
      padding: 0;
      border: none;
      background: transparent;
      border-radius: 0;
    }
  }

  .filter-section {
    padding-bottom: 16px;
    margin-bottom: 16px;
    border-bottom: 1px solid var(--pub-divider-color);
  }

  .filter-title {
    margin: 0 0 10px;
    font-size: 12px;
    font-weight: 700;
    color: var(--pub-default-text-color);
  }

  .filter-checkbox {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 3px 0;
    cursor: pointer;
    color: var(--pub-default-text-color);
    font-size: 13px;
  }

  .clear-filters {
    border: none;
    background: none;
    color: var(--pub-link-text-color);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    padding: 0;
    font-family: inherit;
  }
  .clear-filters:hover { text-decoration: underline; }

  /* Main content */
  .packages-main { min-width: 0; }

  .packages-toolbar {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 8px 16px;
    margin-bottom: 16px;
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }

  .results-count {
    display: flex;
    align-items: baseline;
    gap: 4px;
    letter-spacing: 0.03em;
  }
  .results-count strong {
    font-weight: 700;
    color: var(--pub-default-text-color);
  }
  .results-subtle {
    color: var(--pub-muted-text-color);
    text-transform: none;
    letter-spacing: 0;
  }

  .sort-control {
    display: flex;
    align-items: center;
    gap: 6px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .sort-control select {
    border: none;
    background: transparent;
    color: var(--pub-link-text-color);
    font-size: 12px;
    font-weight: 600;
    font-family: inherit;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    cursor: pointer;
    outline: none;
  }

  .packages-list { display: flex; flex-direction: column; }

  .empty-state {
    border: 1px dashed var(--border);
    border-radius: 12px;
    background: color-mix(in srgb, var(--muted) 60%, transparent);
    padding: 48px 24px;
    text-align: center;
    color: var(--pub-muted-text-color);
  }
  .empty-state p { margin: 0; }

  .pagination {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 16px;
    margin-top: 32px;
  }
  .page-info {
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
</style>
