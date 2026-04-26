<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { api, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import VerifiedBadge from '$lib/components/VerifiedBadge.svelte';

  interface Publisher {
    publisherId: string;
    displayName: string;
    description?: string | null;
    websiteUrl?: string | null;
    contactEmail?: string | null;
    verified: boolean;
    domain?: string;
    createdAt: string;
  }

  let publishers = $state<Publisher[]>([]);
  let loading = $state(true);
  let message = $state('');
  let tone: 'info' | 'error' | 'success' = $state('info');

  // Create-internal form. `?new=1` in the URL opens it immediately, which
  // is what the admin entry point from /my-publishers used to rely on —
  // kept for that back-compat even though the primary "create verified"
  // flow now lives at /publishers/verify.
  let showForm = $state(page.url.searchParams.get('new') === '1');
  let fId = $state('');
  let fName = $state('');
  let fDesc = $state('');
  let fWebsite = $state('');
  let fContact = $state('');
  let fInitialAdminEmail = $state('');
  let creating = $state(false);

  // Delete confirmation state — the server enforces the "no packages"
  // precondition, but the UI still confirms in case of accidental clicks.
  let deleting = $state<Publisher | null>(null);
  let deleteBusy = $state(false);

  $effect(() => {
    load();
  });

  async function load() {
    loading = true;
    try {
      const data = await api.get<{ publishers: Publisher[] }>('/api/publishers');
      publishers = data.publishers ?? [];
    } catch {
      setMsg('Failed to load publishers.', 'error');
    } finally {
      loading = false;
    }
  }

  function setMsg(text: string, t: typeof tone = 'info') {
    message = text;
    tone = t;
  }

  function resetForm() {
    fId = '';
    fName = '';
    fDesc = '';
    fWebsite = '';
    fContact = '';
    fInitialAdminEmail = '';
    showForm = false;
  }

  async function create(e: Event) {
    e.preventDefault();
    if (creating) return;
    if (!fId.trim() || !fName.trim()) return;
    creating = true;
    setMsg('');
    try {
      await api.post('/api/publishers', {
        id: fId.trim(),
        displayName: fName.trim(),
        description: fDesc.trim() || null,
        websiteUrl: fWebsite.trim() || null,
        contactEmail: fContact.trim() || null,
        initialAdminEmail: fInitialAdminEmail.trim() || null,
      });
      setMsg(`Publisher "${fId.trim()}" created.`, 'success');
      resetForm();
      await load();
    } catch (err) {
      setMsg(apiErrorMessage(err, 'Failed to create publisher.'), 'error');
    } finally {
      creating = false;
    }
  }

  function askDelete(p: Publisher) {
    deleting = p;
  }

  async function confirmDelete() {
    const target = deleting;
    if (!target || deleteBusy) return;
    deleteBusy = true;
    try {
      await api.delete(`/api/publishers/${target.publisherId}`);
      setMsg(`Publisher "${target.publisherId}" deleted.`, 'success');
      deleting = null;
      await load();
    } catch (err) {
      setMsg(apiErrorMessage(err, 'Failed to delete publisher.'), 'error');
      deleting = null;
    } finally {
      deleteBusy = false;
    }
  }
</script>

<svelte:head><title>Publishers | Admin | CLUB</title></svelte:head>

<div class="page">
  <header class="page-header">
    <div>
      <h1>Publishers</h1>
      <p class="sub">
        Verified publishers are self-service via DNS proof. Internal publishers
        are admin-created arbitrary namespaces — use them for teams without a
        public domain or for legacy groupings.
      </p>
    </div>
    <div class="header-actions">
      <Button onclick={() => goto('/publishers/verify')}>
        Verify a domain
      </Button>
      {#if !showForm}
        <Button variant="outline" onclick={() => (showForm = true)}>
          Create internal
        </Button>
      {/if}
    </div>
  </header>

  <InlineMessage {message} {tone} />

  {#if showForm}
    <form class="create-form" onsubmit={create}>
      <h2>New internal publisher</h2>
      <p class="note">
        Internal publishers skip DNS verification. IDs must be slugs —
        lowercase letters, digits, and hyphens. Dots are reserved for
        verified (domain-based) publishers.
      </p>
      <div class="grid-2">
        <label>
          <span class="lbl">ID (slug)</span>
          <Input
            bind:value={fId}
            placeholder="my-team"
            disabled={creating}
            required
          />
        </label>
        <label>
          <span class="lbl">Display name</span>
          <Input
            bind:value={fName}
            placeholder="My Team"
            disabled={creating}
            required
          />
        </label>
      </div>
      <label>
        <span class="lbl">Description</span>
        <textarea
          rows="3"
          bind:value={fDesc}
          disabled={creating}
          maxlength="4096"
        ></textarea>
      </label>
      <div class="grid-2">
        <label>
          <span class="lbl">Website</span>
          <Input
            bind:value={fWebsite}
            placeholder="https://..."
            disabled={creating}
          />
        </label>
        <label>
          <span class="lbl">Contact email</span>
          <Input
            type="email"
            bind:value={fContact}
            placeholder="contact@..."
            disabled={creating}
          />
        </label>
      </div>
      <label>
        <span class="lbl">Initial admin email (optional)</span>
        <Input
          type="email"
          bind:value={fInitialAdminEmail}
          placeholder="teamlead@example.com"
          disabled={creating}
        />
        <span class="hint">
          If set, that user becomes the publisher's first admin. Otherwise
          you do.
        </span>
      </label>
      <div class="actions">
        <Button variant="outline" onclick={resetForm} disabled={creating}>
          Cancel
        </Button>
        <Button
          type="submit"
          disabled={creating || !fId.trim() || !fName.trim()}
        >
          {creating ? 'Creating...' : 'Create internal publisher'}
        </Button>
      </div>
    </form>
  {/if}

  {#if loading}
    <p class="empty">Loading publishers...</p>
  {:else if publishers.length === 0}
    <p class="empty">No publishers yet.</p>
  {:else}
    <div class="table-scroll">
    <table class="publishers-table">
      <thead>
        <tr>
          <th>ID</th>
          <th>Display name</th>
          <th>Type</th>
          <th>Contact</th>
          <th>Created</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {#each publishers as p (p.publisherId)}
          <tr>
            <td class="id-cell">
              <a href={`/publishers/${p.publisherId}`}>{p.publisherId}</a>
            </td>
            <td>
              <span class="name">{p.displayName}</span>
              {#if p.verified}
                <VerifiedBadge iconOnly />
              {/if}
            </td>
            <td>
              {#if p.verified}
                <span class="type-badge verified">verified</span>
              {:else}
                <span class="type-badge internal">internal</span>
              {/if}
            </td>
            <td>{p.contactEmail ?? '—'}</td>
            <td>{new Date(p.createdAt).toLocaleDateString()}</td>
            <td>
              <button
                type="button"
                class="delete-btn"
                onclick={() => askDelete(p)}
                title="Delete publisher"
                aria-label={`Delete ${p.publisherId}`}
              >
                ×
              </button>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
    </div>
  {/if}
</div>

<Dialog
  open={deleting !== null}
  title={deleting ? `Delete ${deleting.publisherId}?` : 'Delete publisher'}
  description={deleting
    ? `This removes the publisher entity and all member associations. It will fail if any packages still reference it — transfer or clear those first.`
    : ''}
  confirmLabel="Delete publisher"
  confirmVariant="destructive"
  confirmText={deleting?.publisherId ?? ''}
  busy={deleteBusy}
  onConfirm={confirmDelete}
  onCancel={() => (deleting = null)}
/>

<style>
  .page {
    width: 100%;
    min-width: 0;
  }

  .page-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 1.5rem;
    flex-wrap: wrap;
  }

  h1 {
    margin: 0 0 0.25rem;
    font-size: 1.375rem;
    font-weight: 700;
  }

  .sub {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    max-width: 44rem;
  }

  .header-actions {
    display: flex;
    gap: 0.5rem;
    flex-shrink: 0;
  }

  .create-form {
    padding: 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    margin-bottom: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.875rem;
  }

  .create-form h2 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
  }

  .grid-2 {
    display: grid;
    grid-template-columns: 1fr;
    gap: 0.875rem;
  }
  @media (min-width: 640px) {
    .grid-2 { grid-template-columns: 1fr 1fr; }
  }

  label {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .lbl {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted-foreground);
  }

  .hint {
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }

  textarea {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 0.5rem 0.625rem;
    font: inherit;
    background: var(--background);
    color: var(--foreground);
    resize: vertical;
  }

  textarea:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 35%, transparent);
  }

  .note {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
  }

  .table-scroll {
    width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    margin: 0 -0.5rem;
    padding: 0 0.5rem;
  }
  .publishers-table {
    width: 100%;
    min-width: 640px;
    border-collapse: collapse;
  }

  .publishers-table th {
    text-align: left;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--muted-foreground);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.6rem 0.5rem;
    border-bottom: 2px solid var(--border);
  }

  .publishers-table td {
    padding: 0.75rem 0.5rem;
    border-bottom: 1px solid var(--border);
    font-size: 0.875rem;
    vertical-align: middle;
  }

  .id-cell a {
    color: var(--primary);
    text-decoration: none;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
  }

  .id-cell a:hover {
    text-decoration: underline;
  }

  .name {
    margin-right: 0.35rem;
  }

  .type-badge {
    display: inline-block;
    padding: 0.1rem 0.45rem;
    border-radius: 3px;
    font-size: 0.65rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .type-badge.verified {
    background: color-mix(in srgb, var(--primary) 15%, transparent);
    color: var(--primary);
  }

  .type-badge.internal {
    background: var(--muted);
    color: var(--muted-foreground);
  }

  .delete-btn {
    background: none;
    border: none;
    color: var(--muted-foreground);
    cursor: pointer;
    font-size: 1.25rem;
    line-height: 1;
    padding: 0 0.375rem;
  }

  .delete-btn:hover {
    color: var(--destructive);
  }

  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
