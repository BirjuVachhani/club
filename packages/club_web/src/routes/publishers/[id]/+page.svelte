<script lang="ts">
  import { page } from '$app/state';
  import { api } from '$lib/api/client';
  import PackageCard from '$lib/components/PackageCard.svelte';

  const id = $derived(page.params.id);

  let packages = $state<any[]>([]);
  let totalCount = $state(0);
  let loading = $state(true);

  $effect(() => {
    const current = id;
    // Reset synchronously so old results can't briefly appear while the
    // new request is in flight.
    packages = [];
    totalCount = 0;
    loading = true;
    api
      .get<any>(`/api/publishers/${current}/packages`)
      .then((data) => {
        packages = data.packages ?? [];
        totalCount = data.totalCount ?? packages.length;
      })
      .catch(() => {
        packages = [];
        totalCount = 0;
      })
      .finally(() => (loading = false));
  });
</script>

{#if loading}
  <p class="empty">Loading packages...</p>
{:else if packages.length === 0}
  <p class="empty">This publisher has no packages yet.</p>
{:else}
  <p class="count">{totalCount} package{totalCount === 1 ? '' : 's'}</p>
  <div class="package-list">
    {#each packages as p (p.name)}
      <PackageCard
        package={{
          name: p.name,
          version: p.latestVersion ?? '0.0.0',
          description: p.description,
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
{/if}

<style>
  .count {
    margin: 0 0 1rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
  }

  .package-list {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
