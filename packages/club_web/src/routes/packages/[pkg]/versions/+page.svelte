<script lang="ts">
  import { page } from '$app/stores';
  import { api } from '$lib/api/client';

  interface Version {
    version: string;
    published: string;
  }

  let pkgName = $state('');
  let versions = $state<Version[]>([]);
  let loading = $state(true);
  let error = $state('');

  $effect(() => {
    const unsub = page.subscribe(async (p) => {
      pkgName = p.params.pkg ?? '';
      loading = true;
      error = '';
      try {
        const data = await api.get<{ versions: Version[] }>(`/api/packages/${pkgName}`);
        versions = data.versions ?? [];
      } catch {
        error = 'Failed to load versions.';
      } finally {
        loading = false;
      }
    });
    return unsub;
  });
</script>

<div class="versions-page">
  <h1>Versions of {pkgName}</h1>
  <a href="/packages/{pkgName}" class="back-link">Back to package</a>

  {#if loading}
    <p class="muted">Loading versions...</p>
  {:else if error}
    <p class="error">{error}</p>
  {:else if versions.length === 0}
    <p class="muted">No versions found.</p>
  {:else}
    <table class="versions-table">
      <thead>
        <tr>
          <th>Version</th>
          <th>Published</th>
        </tr>
      </thead>
      <tbody>
        {#each versions as v}
          <tr>
            <td class="version-cell">{v.version}</td>
            <td class="date-cell">{new Date(v.published).toLocaleDateString(undefined, {
              year: 'numeric',
              month: 'short',
              day: 'numeric',
              hour: '2-digit',
              minute: '2-digit'
            })}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  {/if}
</div>

<style>
  .versions-page {
    max-width: 700px;
  }

  .versions-page h1 {
    font-size: 24px;
    margin-bottom: 8px;
  }

  .back-link {
    font-size: 14px;
    display: inline-block;
    margin-bottom: 24px;
  }

  .versions-table {
    width: 100%;
    border-collapse: collapse;
  }

  .versions-table th {
    text-align: left;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--pub-muted-text-color);
    padding: 8px 12px;
    border-bottom: 2px solid var(--pub-divider-color);
  }

  .versions-table td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--pub-divider-color);
    font-size: 14px;
  }

  .version-cell {
    font-family: var(--pub-code-font-family);
    font-weight: 600;
  }

  .date-cell {
    color: var(--pub-muted-text-color);
  }

  .muted {
    color: var(--pub-muted-text-color);
    font-style: italic;
  }

  .error {
    color: var(--pub-error-color);
  }
</style>
