<script lang="ts">
  import { onMount } from 'svelte';
  import { invalidateAll } from '$app/navigation';
  import { api, apiErrorMessage } from '$lib/api/client';

  let settings = $state<{ disableSites: boolean } | null>(null);
  let busy = $state(false);
  let error = $state('');
  let message = $state('');

  onMount(async () => {
    try { settings = await api.get('/api/admin/sites/settings'); }
    catch (e) { error = apiErrorMessage(e, 'Failed to load settings.'); }
  });

  async function save(disableSites: boolean) {
    busy = true;
    error = '';
    message = '';
    try {
      settings = await api.put('/api/admin/sites/settings', { disableSites });
      message = 'Saved.';
      await invalidateAll();
    } catch (e) { error = apiErrorMessage(e, 'Could not save.'); }
    finally { busy = false; }
  }
</script>

<svelte:head><title>Sites · Admin · club</title></svelte:head>
<div class="max-w-[640px]">
  <h1 class="mb-1 text-[26px] font-bold">Sites</h1>
  <p class="mb-5 text-sm text-[var(--muted-foreground)]">Control access to package sites across this server.</p>
  {#if error}<p role="alert" class="mb-3 text-sm text-red-600">{error}</p>{/if}
  {#if message}<p role="status" class="mb-3 text-sm">{message}</p>{/if}
  {#if settings}
    <div class="rounded-[10px] border border-[var(--border)] bg-[var(--card)] p-4">
      <label class="flex cursor-pointer items-start gap-2.5 py-2">
        <input type="checkbox" checked={settings.disableSites} disabled={busy} onchange={(e) => save(e.currentTarget.checked)} />
        <span class="text-sm">
          <strong>Disable sites</strong>
          <span class="mt-1 block text-[var(--muted-foreground)]">Hide Sites in package sidebars and block Club links to archived previews and external sites, including for admins. Off by default. Publishing is unchanged.</span>
        </span>
      </label>
      <p class="mt-3 text-sm text-[var(--muted-foreground)]">Already opened previews and downloaded files cannot be revoked. External websites remain accessible at their own URLs.</p>
    </div>
  {:else if !error}<p class="text-sm text-[var(--muted-foreground)]">Loading...</p>{/if}
</div>
