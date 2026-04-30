<script lang="ts">
  import { goto } from '$app/navigation';
  import { api, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { auth } from '$lib/stores/auth';
  import {
    canTransferServerOwnership,
    isServerAdmin,
  } from '$lib/utils/permissions';

  const user = $derived($auth.user);
  const canTransfer = $derived(canTransferServerOwnership(user));

  let targetEmail = $state('');
  let confirmEmail = $state('');
  let dialogOpen = $state(false);
  let busy = $state(false);
  let message = $state('');
  let tone: 'info' | 'error' | 'success' = $state('info');

  const mismatched = $derived(
    targetEmail.trim().length > 0 &&
      confirmEmail.trim().length > 0 &&
      targetEmail.trim().toLowerCase() !== confirmEmail.trim().toLowerCase(),
  );

  const ready = $derived(
    targetEmail.trim().length > 0 &&
      confirmEmail.trim().length > 0 &&
      !mismatched,
  );

  function startTransfer() {
    if (!ready) return;
    message = '';
    dialogOpen = true;
  }

  async function doTransfer() {
    if (busy) return;
    busy = true;
    try {
      await api.post('/api/admin/transfer-ownership', {
        email: targetEmail.trim(),
      });
      message = `Ownership transferred to ${targetEmail.trim()}.`;
      tone = 'success';
      dialogOpen = false;
      // The server has demoted this session's user to admin. Refresh to
      // re-hydrate the role from /api/auth/me before further navigation.
      setTimeout(() => goto('/admin/settings/stats'), 1200);
    } catch (err) {
      message = apiErrorMessage(err, 'Failed to transfer ownership.');
      tone = 'error';
      dialogOpen = false;
    } finally {
      busy = false;
    }
  }
</script>

<svelte:head><title>Ownership · Admin | CLUB</title></svelte:head>

<h1 class="title">Server ownership</h1>

{#if !isServerAdmin(user)}
  <p class="empty">Admin access required.</p>
{:else if !canTransfer}
  <div class="lock">
    <h2>You are not the owner</h2>
    <p>
      Only the current <strong>owner</strong> of this server can transfer ownership. Server admins cannot perform this action.
    </p>
  </div>
{:else}
  <section class="card">
    <h2>About ownership</h2>
    <ul>
      <li>The <strong>owner</strong> role is unique — exactly one user per server holds it.</li>
      <li>Only the owner can promote or demote admins and transfer ownership.</li>
      <li>Transferring ownership is <strong>immediate</strong> and <strong>irrevocable by you</strong> — after transfer you become an admin, and only the new owner can transfer back.</li>
    </ul>
  </section>

  <section class="card">
    <h2>Transfer ownership</h2>
    <p class="desc">Enter the email of the existing user who should become the new owner.</p>

    <InlineMessage {message} {tone} />

    <div class="form">
      <label>
        <span class="lbl">New owner email</span>
        <Input type="email" bind:value={targetEmail} placeholder="new-owner@example.com" />
      </label>
      <label>
        <span class="lbl">Confirm email</span>
        <Input type="email" bind:value={confirmEmail} placeholder="new-owner@example.com" />
      </label>
      {#if mismatched}
        <p class="mismatch">Emails don't match.</p>
      {/if}
      <div class="actions">
        <Button variant="destructive" disabled={!ready} onclick={startTransfer}>
          Transfer ownership
        </Button>
      </div>
    </div>
  </section>
{/if}

<Dialog
  bind:open={dialogOpen}
  title="Transfer server ownership?"
  description={`Ownership will move to ${targetEmail.trim()}. You will be demoted to admin and cannot undo this unless the new owner transfers back.`}
  confirmLabel="Transfer"
  confirmVariant="destructive"
  confirmText="transfer ownership"
  {busy}
  onConfirm={doTransfer}
>
  {#snippet typedPrompt()}
    Type <code>"transfer ownership"</code> to confirm transfer.
  {/snippet}
</Dialog>

<style>
  .title {
    font-size: 1.375rem;
    font-weight: 700;
    margin: 0 0 1.25rem;
  }
  .card {
    padding: 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    margin-bottom: 1rem;
  }
  h2 {
    margin: 0 0 0.75rem;
    font-size: 1.0625rem;
    font-weight: 600;
  }
  ul { margin: 0; padding-left: 1.1rem; font-size: 0.875rem; line-height: 1.7; }
  li { margin-bottom: 0.2rem; }
  .desc { margin: 0 0 0.875rem; font-size: 0.875rem; color: var(--muted-foreground); }
  .form {
    display: flex;
    flex-direction: column;
    gap: 0.875rem;
    max-width: 26rem;
  }
  label {
    display: flex;
    flex-direction: column;
    gap: 0.3rem;
  }
  .lbl {
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted-foreground);
  }
  .mismatch {
    margin: 0;
    color: var(--destructive);
    font-size: 0.8125rem;
  }
  .actions { display: flex; justify-content: flex-end; margin-top: 0.25rem; }
  .lock {
    padding: 1.5rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--muted);
    color: var(--muted-foreground);
  }
  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
