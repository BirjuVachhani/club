<script lang="ts">
  import Alert from '$lib/components/ui/Alert.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Card from '$lib/components/ui/Card.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { api, ApiError } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';
  import { confirmDialog } from '$lib/stores/confirm';
  import { isServerAdmin } from '$lib/utils/permissions';
  import { onMount } from 'svelte';

  type Scope = 'read' | 'write' | 'admin';

  interface ApiKey {
    id: string;
    name: string;
    prefix: string;
    scopes: string[];
    createdAt: string;
    expiresAt?: string | null;
    lastUsedAt?: string | null;
  }

  let keys = $state<ApiKey[]>([]);
  let loading = $state(true);
  let dialogOpen = $state(false);
  let newName = $state('');
  let scopeRead = $state(true);
  let scopeWrite = $state(true);
  let scopeAdmin = $state(false);
  // Empty string = no expiry. Numeric strings are whole days.
  let expiresInDays = $state<string>('');
  let createdSecret = $state<string | null>(null);
  let creating = $state(false);
  let error = $state('');
  let dialogError = $state('');

  const user = $derived($auth.user);
  const canAdminScope = $derived(isServerAdmin(user));

  const scopes = $derived<Scope[]>(
    [
      scopeRead ? 'read' : null,
      scopeWrite ? 'write' : null,
      scopeAdmin && canAdminScope ? 'admin' : null,
    ].filter((s): s is Scope => s !== null),
  );

  function setExpiryPreset(days: number | null) {
    expiresInDays = days === null ? '' : String(days);
  }

  onMount(async () => {
    await loadKeys();
  });

  async function loadKeys() {
    loading = true;
    error = '';
    try {
      const data = await api.get<{ keys: ApiKey[] }>('/api/auth/keys');
      keys = data.keys ?? [];
    } catch {
      error = 'Failed to load API keys.';
    } finally {
      loading = false;
    }
  }

  function resetForm() {
    newName = '';
    scopeRead = true;
    scopeWrite = true;
    scopeAdmin = false;
    expiresInDays = '';
    dialogError = '';
  }

  function openDialog() {
    resetForm();
    createdSecret = null;
    dialogOpen = true;
  }

  async function createKey() {
    if (creating) return;

    dialogError = '';
    if (!newName.trim()) {
      dialogError = 'Name is required.';
      return;
    }
    if (scopes.length === 0) {
      dialogError = 'Select at least one scope.';
      return;
    }
    const days = expiresInDays.trim() ? parseInt(expiresInDays, 10) : null;
    if (days !== null && (!Number.isFinite(days) || days <= 0)) {
      dialogError = 'Expiry (days) must be a positive number.';
      return;
    }

    creating = true;
    createdSecret = null;

    try {
      const body: Record<string, unknown> = {
        name: newName.trim(),
        scopes,
      };
      if (days !== null) body.expiresInDays = days;

      const data = await api.post<{ secret: string; id: string; name: string }>(
        '/api/auth/keys',
        body,
      );
      createdSecret = data.secret;
      dialogOpen = false;
      resetForm();
      await loadKeys();
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { error?: { message?: string }; message?: string } | undefined;
        dialogError = body?.error?.message ?? body?.message ?? 'Failed to create API key.';
      } else {
        dialogError = 'Failed to create API key.';
      }
    } finally {
      creating = false;
    }
  }

  async function revokeKey(id: string) {
    const ok = await confirmDialog({
      title: 'Revoke API key?',
      description: 'Anything using it will stop working.',
      confirmLabel: 'Revoke',
      confirmVariant: 'destructive'
    });
    if (!ok) return;

    try {
      await api.delete(`/api/auth/keys/${id}`);
      keys = keys.filter((t) => t.id !== id);
    } catch {
      error = 'Failed to revoke key.';
    }
  }
</script>

<div class="space-y-6">
  <div>
    <h2 class="mb-1 text-2xl font-semibold tracking-tight">API keys</h2>
    <p class="m-0 text-sm text-[var(--muted-foreground)]">
      Long-lived keys for the CLI, <code>dart pub</code>, CI pipelines, and other
      programmatic clients. Pass as <code>Authorization: Bearer</code>.
    </p>
  </div>

  {#if error}
    <Alert class="border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_10%,var(--card))] text-[var(--destructive)]">
      {error}
    </Alert>
  {/if}

  {#if createdSecret}
    <Alert class="border-[var(--success)]/30 bg-[color:color-mix(in_srgb,var(--success)_10%,var(--card))] text-[var(--foreground)]">
      <p class="mb-3 mt-0 text-sm"><strong>Key created.</strong> Copy it now — it will not be shown again.</p>
      <code class="secret-value">{createdSecret}</code>
    </Alert>
  {/if}

  <Card class="p-6">
    <div class="mb-4 flex items-start justify-between gap-4">
      <div>
        <h3 class="mb-1 text-lg font-semibold">Active keys</h3>
        <p class="m-0 text-sm text-[var(--muted-foreground)]">Revoke keys you no longer trust or use.</p>
      </div>
      <Button onclick={openDialog}>New key</Button>
    </div>

    {#if loading}
      <p class="text-sm italic text-[var(--muted-foreground)]">Loading keys...</p>
    {:else if keys.length === 0}
      <p class="text-sm italic text-[var(--muted-foreground)]">No keys yet.</p>
    {:else}
      <div class="table-scroll">
      <table class="keys-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Prefix</th>
            <th>Created</th>
            <th>Last Used</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {#each keys as key}
            <tr>
              <td class="key-name">{key.name}</td>
              <td class="key-prefix"><code>{key.prefix}…</code></td>
              <td class="key-date">{new Date(key.createdAt).toLocaleDateString()}</td>
              <td class="key-date">
                {key.lastUsedAt ? new Date(key.lastUsedAt).toLocaleDateString() : 'Never'}
              </td>
              <td>
                <Button variant="outline" size="sm" class="border-[var(--destructive)] text-[var(--destructive)] hover:bg-[color:color-mix(in_srgb,var(--destructive)_10%,transparent)]" onclick={() => revokeKey(key.id)}>Revoke</Button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
      </div>
    {/if}
  </Card>
</div>

<Dialog
  bind:open={dialogOpen}
  title="Create a new key"
  description="Keys are shown only once. Store them before leaving this page."
  confirmLabel="Create Key"
  busy={creating}
  onConfirm={createKey}
  onCancel={resetForm}
>
  {#snippet body()}
    <div class="flex flex-col gap-4">
      {#if dialogError}
        <InlineMessage message={dialogError} tone="error" />
      {/if}

      <Input
        type="text"
        bind:value={newName}
        placeholder="Key name (e.g., CI/CD)"
      />

      <div class="scope-group">
        <span class="group-label">Scopes</span>
        <div class="scope-row">
          <label class="scope-check">
            <input type="checkbox" bind:checked={scopeRead} />
            <span><strong>read</strong> — fetch metadata, download archives, search</span>
          </label>
          <label class="scope-check">
            <input type="checkbox" bind:checked={scopeWrite} />
            <span><strong>write</strong> — publish versions, manage package options</span>
          </label>
          <label class="scope-check" class:disabled={!canAdminScope}>
            <input type="checkbox" bind:checked={scopeAdmin} disabled={!canAdminScope} />
            <span>
              <strong>admin</strong> — server-wide administration
              {#if !canAdminScope}<em>(requires admin role)</em>{/if}
            </span>
          </label>
        </div>
      </div>

      <div class="expiry-group">
        <span class="group-label">Expiry</span>
        <div class="expiry-row">
          <Input
            type="number"
            min="1"
            bind:value={expiresInDays}
            placeholder="Days (blank = no expiry)"
          />
          <div class="preset-row">
            <button type="button" class="preset" onclick={() => setExpiryPreset(30)}>30 days</button>
            <button type="button" class="preset" onclick={() => setExpiryPreset(90)}>90 days</button>
            <button type="button" class="preset" onclick={() => setExpiryPreset(180)}>180 days</button>
            <button type="button" class="preset" onclick={() => setExpiryPreset(365)}>1 year</button>
            <button type="button" class="preset" onclick={() => setExpiryPreset(null)}>No expiry</button>
          </div>
        </div>
      </div>
    </div>
  {/snippet}
</Dialog>

<style>
  .secret-value {
    display: block;
    padding: 10px 12px;
    background: var(--pub-default-background);
    border: 1px solid var(--pub-input-border);
    border-radius: 4px;
    font-size: 13px;
    word-break: break-all;
    -webkit-user-select: all;
    user-select: all;
  }

  .keys-table {
    width: 100%;
    border-collapse: collapse;
  }

  .keys-table th {
    text-align: left;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--pub-muted-text-color);
    padding: 8px 12px;
    border-bottom: 2px solid var(--pub-divider-color);
  }

  .keys-table td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--pub-divider-color);
    font-size: 14px;
  }

  .key-name {
    font-weight: 600;
  }

  .key-prefix code {
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }

  .key-date {
    color: var(--pub-muted-text-color);
  }

  .group-label {
    display: block;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted-foreground);
    margin-bottom: 0.4rem;
  }
  .scope-row {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .scope-check {
    display: flex;
    gap: 0.5rem;
    align-items: flex-start;
    font-size: 0.875rem;
    cursor: pointer;
  }
  .scope-check input {
    margin-top: 0.18rem;
  }
  .scope-check.disabled {
    color: var(--muted-foreground);
    cursor: not-allowed;
  }
  .scope-check em {
    color: var(--muted-foreground);
    font-style: normal;
    font-size: 0.75rem;
    margin-left: 0.25rem;
  }
  .expiry-row {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .preset-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
  }
  .preset {
    padding: 0.25rem 0.55rem;
    border: 1px solid var(--border);
    border-radius: 999px;
    background: var(--card);
    color: var(--muted-foreground);
    font-size: 0.75rem;
    cursor: pointer;
  }
  .preset:hover {
    border-color: var(--primary);
    color: var(--primary);
  }

  .table-scroll {
    width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
  }

  @media (max-width: 640px) {
    .keys-table th:nth-child(4),
    .keys-table td:nth-child(4) {
      display: none;
    }
  }
</style>
