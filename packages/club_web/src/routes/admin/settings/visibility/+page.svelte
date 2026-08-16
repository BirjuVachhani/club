<script lang="ts">
  /**
   * Server-wide control for public packages.
   *
   * This is one half of the gate. The other half is the
   * `PUBLIC_PACKAGES_ENABLED` environment variable, which only whoever
   * controls the deployment can set. Requiring both means an existing
   * private registry cannot acquire an anonymous surface from a single
   * click here, an upgrade, or a compromised admin session alone.
   */
  import { onMount } from 'svelte';
  import { api, apiErrorMessage } from '$lib/api/client';
  import { confirmDialog } from '$lib/stores/confirm';

  interface Settings {
    permittedByEnvironment: boolean;
    enabled: boolean;
    requiresServerAdmin: boolean;
    totalPackages: number;
    publicPackages: number;
  }

  let settings = $state<Settings | null>(null);
  let loading = $state(true);
  let busy = $state(false);
  let error = $state('');
  let message = $state('');

  async function load() {
    loading = true;
    error = '';
    try {
      settings = await api.get<Settings>('/api/admin/public-packages');
    } catch (e) {
      error = apiErrorMessage(e, 'Failed to load settings.');
    } finally {
      loading = false;
    }
  }

  onMount(load);

  async function setEnabled(next: boolean) {
    if (!settings) return;

    if (next) {
      const ok = await confirmDialog({
        title: 'Enable public packages?',
        description: [
          'This allows package owners to mark their packages public. A ' +
            'public package is readable and downloadable by anyone with no ' +
            'account, and resolves with `dart pub get` without a token.',
          '',
          'Nothing becomes public immediately: every package stays private ' +
            'until someone deliberately flips it and confirms what goes ' +
            'with it.',
          '',
          'Turning this back off makes every public package require ' +
            'credentials again straight away, with no per-package change to ' +
            'undo. It does not recall anything already downloaded.'
        ].join('\n'),
        confirmLabel: 'Enable',
        confirmVariant: 'destructive'
      });
      if (!ok) return;
    } else if (settings.publicPackages > 0) {
      const ok = await confirmDialog({
        title: 'Disable public packages?',
        description:
          `${settings.publicPackages} package(s) are currently public. ` +
          'They will immediately require credentials again, which will break ' +
          'anonymous `dart pub get` for anyone depending on them. Their ' +
          'public/private flags are preserved, so re-enabling restores ' +
          'access exactly as it was.',
        confirmLabel: 'Disable',
        confirmVariant: 'destructive'
      });
      if (!ok) return;
    }

    await save({ enabled: next });
  }

  async function save(body: Record<string, unknown>) {
    busy = true;
    error = '';
    message = '';
    try {
      settings = await api.put<Settings>('/api/admin/public-packages', body);
      message = 'Saved.';
    } catch (e) {
      error = apiErrorMessage(e, 'Could not save.');
    } finally {
      busy = false;
    }
  }
</script>

<svelte:head><title>Public packages · Admin · club</title></svelte:head>

<div class="page">
  <h1>Public packages</h1>
  <p class="lede">
    Control whether packages on this server can be shared without an account.
  </p>

  {#if loading}
    <p class="muted">Loading...</p>
  {:else if !settings}
    <p class="error">{error || 'Unavailable.'}</p>
  {:else}
    {#if error}<p class="error">{error}</p>{/if}
    {#if message}<p class="ok">{message}</p>{/if}

    {#if !settings.permittedByEnvironment}
      <div class="card blocked">
        <strong>Disabled for this deployment</strong>
        <p>
          Set <code>PUBLIC_PACKAGES_ENABLED=true</code> in the server
          environment and restart before public packages can be enabled here.
          This second gate exists so that an existing private registry cannot
          be opened up from the dashboard alone.
        </p>
      </div>
    {/if}

    <div class="card">
      <label class="toggle">
        <input
          type="checkbox"
          checked={settings.enabled}
          disabled={busy || !settings.permittedByEnvironment}
          onchange={(e) => setEnabled(e.currentTarget.checked)}
        />
        <span>
          <strong>Allow packages to be marked public</strong>
          <span class="hint">
            Package owners can then share individual packages. Everything stays
            private until they do.
          </span>
        </span>
      </label>

      <label class="toggle">
        <input
          type="checkbox"
          checked={settings.requiresServerAdmin}
          disabled={busy || !settings.enabled}
          onchange={(e) => save({ requiresServerAdmin: e.currentTarget.checked })}
        />
        <span>
          <strong>Require a server admin to change visibility</strong>
          <span class="hint">
            Off by default, so package owners self-serve. Turn on if one
            uploader publishing company source to the internet should be
            reviewed first: package admin includes any single direct uploader.
          </span>
        </span>
      </label>
    </div>

    <div class="card stats">
      <div><span class="n">{settings.publicPackages}</span> public</div>
      <div>
        <span class="n">{settings.totalPackages - settings.publicPackages}</span>
        private
      </div>
    </div>
  {/if}
</div>

<style>
  .page {
    max-width: 640px;
  }
  h1 {
    font-size: 26px;
    font-weight: 700;
    margin: 0 0 4px;
  }
  .lede {
    color: var(--muted-foreground);
    margin: 0 0 20px;
    font-size: 14px;
  }
  .card {
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 16px;
    margin-bottom: 12px;
    background: var(--card);
  }
  .blocked {
    background: var(--muted);
  }
  .blocked p {
    margin: 6px 0 0;
    font-size: 13px;
    color: var(--muted-foreground);
  }
  .toggle {
    display: flex;
    gap: 10px;
    align-items: flex-start;
    padding: 8px 0;
    cursor: pointer;
  }
  .toggle + .toggle {
    border-top: 1px solid var(--border);
    margin-top: 8px;
    padding-top: 16px;
  }
  .toggle span {
    display: block;
    font-size: 14px;
  }
  .hint {
    color: var(--muted-foreground);
    font-size: 13px;
    margin-top: 2px;
  }
  .stats {
    display: flex;
    gap: 32px;
    font-size: 13px;
    color: var(--muted-foreground);
  }
  .n {
    font-size: 22px;
    font-weight: 700;
    color: var(--foreground);
    display: block;
  }
  .error,
  .ok {
    font-size: 13px;
    padding: 8px 10px;
    border-radius: 8px;
    margin-bottom: 12px;
  }
  .error {
    background: color-mix(in srgb, #dc2626 12%, transparent);
    color: #dc2626;
  }
  .ok {
    background: color-mix(in srgb, #16a34a 12%, transparent);
    color: #16a34a;
  }
  .muted {
    color: var(--muted-foreground);
  }
</style>
