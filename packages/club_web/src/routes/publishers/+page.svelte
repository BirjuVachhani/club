<script lang="ts">
  import { api } from '$lib/api/client';

  let publishers = $state<any[]>([]);
  let loading = $state(true);

  $effect(() => {
    api.get<any>('/api/publishers').then((data) => {
      publishers = data.publishers ?? [];
      loading = false;
    }).catch(() => { loading = false; });
  });
</script>

<div class="publishers-page">
  <h1>Publishers</h1>

  {#if loading}
    <p>Loading...</p>
  {:else if publishers.length === 0}
    <p>No publishers found.</p>
  {:else}
    <div class="publisher-list">
      {#each publishers as pub}
        <a href="/publishers/{pub.publisherId}" class="publisher-card">
          <h3>{pub.displayName}</h3>
          <p class="publisher-id">{pub.publisherId}</p>
          {#if pub.description}
            <p class="description">{pub.description}</p>
          {/if}
        </a>
      {/each}
    </div>
  {/if}
</div>

<style>
  .publisher-list {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
    gap: 1rem;
  }
  .publisher-card {
    display: block;
    padding: 1.5rem;
    border: 1px solid var(--pub-divider-color, #eee);
    border-radius: 8px;
    text-decoration: none;
    color: inherit;
    transition: box-shadow 0.2s;
  }
  .publisher-card:hover {
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
  }
  .publisher-id {
    color: var(--pub-secondary-text-color, #666);
    font-size: 0.875rem;
  }
  .description {
    margin-top: 0.5rem;
    color: var(--pub-secondary-text-color, #666);
  }
</style>
