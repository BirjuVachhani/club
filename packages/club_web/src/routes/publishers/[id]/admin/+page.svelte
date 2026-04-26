<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { api, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { confirmDialog } from '$lib/stores/confirm';

  const id = $derived(page.params.id);

  interface Publisher {
    publisherId: string;
    displayName: string;
    description?: string | null;
    websiteUrl?: string | null;
    contactEmail?: string | null;
  }

  interface Member {
    userId: string;
    email?: string | null;
    displayName?: string | null;
    role: 'admin' | 'member';
  }

  let publisher = $state<Publisher | null>(null);
  let members = $state<Member[]>([]);
  let loading = $state(true);

  // Info form
  let formDescription = $state('');
  let formWebsite = $state('');
  let formContact = $state('');
  let savingInfo = $state(false);
  let infoMessage = $state('');
  let infoTone: 'info' | 'error' | 'success' = $state('info');

  // Add member form
  let newEmail = $state('');
  let newRole = $state<'admin' | 'member'>('member');
  let addingMember = $state(false);
  let memberMessage = $state('');
  let memberTone: 'info' | 'error' | 'success' = $state('info');

  // Delete publisher state. Server enforces the "no packages" guard;
  // the confirm dialog is pure UX polish for an irreversible action.
  let deleteOpen = $state(false);
  let deleteBusy = $state(false);
  let deleteMessage = $state('');
  let deleteTone: 'info' | 'error' | 'success' = $state('info');

  async function deletePublisher() {
    if (deleteBusy) return;
    deleteBusy = true;
    deleteMessage = '';
    try {
      await api.delete(`/api/publishers/${id}`);
      // Leave the now-gone detail page and land on /my-publishers so the
      // user sees the updated list without a dead reference in history.
      goto('/my-publishers');
    } catch (err) {
      deleteMessage = apiErrorMessage(err, 'Failed to delete publisher.');
      deleteTone = 'error';
      deleteOpen = false;
    } finally {
      deleteBusy = false;
    }
  }

  $effect(() => {
    load();
  });

  async function load() {
    loading = true;
    try {
      const [p, m] = await Promise.all([
        api.get<Publisher>(`/api/publishers/${id}`),
        api.get<{ members: Member[] }>(`/api/publishers/${id}/members`),
      ]);
      publisher = p;
      members = m.members ?? [];
      formDescription = p.description ?? '';
      formWebsite = p.websiteUrl ?? '';
      formContact = p.contactEmail ?? '';
    } catch {
      publisher = null;
    } finally {
      loading = false;
    }
  }

  async function saveInfo(e: Event) {
    e.preventDefault();
    if (savingInfo) return;
    savingInfo = true;
    infoMessage = '';
    try {
      await api.put(`/api/publishers/${id}`, {
        description: formDescription || null,
        websiteUrl: formWebsite || null,
        contactEmail: formContact || null,
      });
      infoMessage = 'Publisher details updated.';
      infoTone = 'success';
      await load();
    } catch (err) {
      infoMessage = apiErrorMessage(err, 'Failed to update publisher.');
      infoTone = 'error';
    } finally {
      savingInfo = false;
    }
  }

  async function addMember(e: Event) {
    e.preventDefault();
    if (addingMember || !newEmail.trim()) return;
    addingMember = true;
    memberMessage = '';
    try {
      await api.post(`/api/publishers/${id}/members`, {
        email: newEmail.trim(),
        role: newRole,
      });
      memberMessage = `Added ${newEmail.trim()}.`;
      memberTone = 'success';
      newEmail = '';
      newRole = 'member';
      await load();
    } catch (err) {
      memberMessage = apiErrorMessage(err, 'Failed to add member.');
      memberTone = 'error';
    } finally {
      addingMember = false;
    }
  }

  async function removeMember(m: Member) {
    const ok = await confirmDialog({
      title: 'Remove member?',
      description: `Remove ${m.email ?? m.userId} from this publisher?`,
      confirmLabel: 'Remove',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    try {
      await api.delete(`/api/publishers/${id}/members/${m.userId}`);
      memberMessage = 'Member removed.';
      memberTone = 'success';
      await load();
    } catch (err) {
      memberMessage = apiErrorMessage(err, 'Failed to remove member.');
      memberTone = 'error';
    }
  }
</script>

{#if loading}
  <p class="empty">Loading...</p>
{:else if publisher}
  <div class="grid">
    <section>
      <h2>Publisher information</h2>
      {#if infoMessage}
        <InlineMessage message={infoMessage} tone={infoTone} />
      {/if}
      <form class="form" onsubmit={saveInfo}>
        <label>
          <span class="lbl">Description</span>
          <textarea
            rows="4"
            maxlength="4096"
            bind:value={formDescription}
            placeholder="What this publisher does"
            disabled={savingInfo}
          ></textarea>
        </label>
        <label>
          <span class="lbl">Website</span>
          <Input bind:value={formWebsite} placeholder="https://example.com" disabled={savingInfo} />
        </label>
        <label>
          <span class="lbl">Contact email</span>
          <Input type="email" bind:value={formContact} placeholder="contact@example.com" disabled={savingInfo} />
        </label>
        <div class="actions">
          <Button type="submit" disabled={savingInfo}>
            {savingInfo ? 'Saving...' : 'Update'}
          </Button>
        </div>
      </form>
    </section>

    <section>
      <h2>Members</h2>
      {#if memberMessage}
        <InlineMessage message={memberMessage} tone={memberTone} />
      {/if}
      <table class="members-table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Name</th>
            <th>Role</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {#each members as m (m.userId)}
            <tr>
              <td>{m.email ?? '—'}</td>
              <td>{m.displayName ?? '—'}</td>
              <td>{m.role}</td>
              <td>
                <button class="x-btn" onclick={() => removeMember(m)} title="Remove">×</button>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>

      <form class="form add-member" onsubmit={addMember}>
        <label class="grow">
          <span class="lbl">Email</span>
          <Input type="email" bind:value={newEmail} placeholder="email@example.com" disabled={addingMember} />
        </label>
        <label>
          <span class="lbl">Role</span>
          <select bind:value={newRole} disabled={addingMember} class="select">
            <option value="member">member</option>
            <option value="admin">admin</option>
          </select>
        </label>
        <Button type="submit" disabled={addingMember || !newEmail.trim()}>
          {addingMember ? 'Adding...' : 'Add member'}
        </Button>
      </form>
    </section>

    <section class="danger">
      <h2>Danger zone</h2>
      <InlineMessage message={deleteMessage} tone={deleteTone} />
      <p class="danger-desc">
        Deleting this publisher removes it and every member association.
        It will fail if any packages still reference it — transfer or
        clear those packages first.
      </p>
      <Button variant="destructive" onclick={() => (deleteOpen = true)}>
        Delete this publisher
      </Button>
    </section>
  </div>

  <Dialog
    bind:open={deleteOpen}
    title={`Delete publisher ${publisher.publisherId}?`}
    description="This cannot be undone. The publisher, its member list, and its activity log will be removed."
    confirmLabel="Delete publisher"
    confirmVariant="destructive"
    confirmText={publisher.publisherId}
    busy={deleteBusy}
    onConfirm={deletePublisher}
  />
{:else}
  <p class="empty">Publisher not found.</p>
{/if}

<style>
  .grid {
    display: grid;
    gap: 2rem;
  }

  section {
    padding: 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
  }

  h2 {
    margin: 0 0 1rem;
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--foreground);
  }

  .form {
    display: flex;
    flex-direction: column;
    gap: 0.875rem;
  }

  .form label {
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

  .select {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 0.5rem 2rem 0.5rem 0.625rem;
    font: inherit;
    background: var(--background);
    color: var(--foreground);
    height: 2.5rem;
  }

  .actions {
    display: flex;
    justify-content: flex-end;
  }

  .members-table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 1rem;
  }

  .members-table th {
    text-align: left;
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--muted-foreground);
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 0.5rem;
    border-bottom: 2px solid var(--border);
  }

  .members-table td {
    padding: 0.65rem 0.5rem;
    border-bottom: 1px solid var(--border);
    font-size: 0.875rem;
  }

  .x-btn {
    background: none;
    border: none;
    color: var(--muted-foreground);
    cursor: pointer;
    font-size: 1.25rem;
    line-height: 1;
    padding: 0 0.375rem;
  }

  .x-btn:hover {
    color: var(--destructive);
  }

  .add-member {
    flex-direction: row;
    align-items: flex-end;
    gap: 0.75rem;
  }

  .grow {
    flex: 1;
  }

  .danger {
    border-color: color-mix(in srgb, var(--destructive) 30%, var(--border));
    background: color-mix(in srgb, var(--destructive) 4%, var(--card));
  }

  .danger h2 {
    color: var(--destructive);
  }

  .danger-desc {
    margin: 0 0 0.75rem;
    font-size: 0.875rem;
    color: var(--muted-foreground);
    line-height: 1.55;
  }

  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
