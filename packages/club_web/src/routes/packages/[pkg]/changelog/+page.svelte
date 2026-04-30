<script lang="ts">
  import MarkdownRenderer from '$lib/components/MarkdownRenderer.svelte';
  import { api } from '$lib/api/client';
  import { page } from '$app/stores';

  let changelog = $state('');
  let loading = $state(true);

  $effect(() => {
    const pkg = $page.params.pkg;
    // `/api/packages/<pkg>` returns PackageData whose `latest` is a
    // VersionInfo — metadata only (version, pubspec, archive info).
    // readme/changelog/example live in separate columns on the version
    // row and are served via the `/content` endpoint.
    api
      .get<any>(`/api/packages/${pkg}/content`)
      .then((data) => {
        changelog = data?.changelog ?? 'No changelog available.';
        loading = false;
      })
      .catch(() => {
        changelog = 'No changelog available.';
        loading = false;
      });
  });
</script>

<div class="changelog-page">
  <h2>Changelog</h2>
  {#if loading}
    <p>Loading...</p>
  {:else}
    <MarkdownRenderer content={changelog} />
  {/if}
</div>
