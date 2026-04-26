<script lang="ts">
  import Alert from '$lib/components/ui/Alert.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Card from '$lib/components/ui/Card.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { api, ApiError } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';

  let currentPassword = $state('');
  let newPassword = $state('');
  let confirmPassword = $state('');
  let error = $state('');
  let success = $state('');
  let saving = $state(false);

  async function changePassword(event: Event) {
    event.preventDefault();
    error = '';
    success = '';

    if (!currentPassword || !newPassword || !confirmPassword) {
      error = 'Fill in all password fields.';
      return;
    }
    if (newPassword.length < 8) {
      error = 'New password must be at least 8 characters.';
      return;
    }
    if (newPassword !== confirmPassword) {
      error = 'New password and confirmation do not match.';
      return;
    }

    saving = true;
    try {
      await api.post('/api/auth/change-password', {
        currentPassword,
        newPassword
      });
      // The server revoked every session (including this one) and cleared
      // the cookies. Redirect the user to sign in again.
      auth.logout();
      window.location.href = '/login?redirect=/settings/security';
      return;
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { error?: { message?: string }; message?: string } | undefined;
        error = body?.error?.message ?? body?.message ?? 'Failed to update password.';
      } else {
        error = 'Failed to update password.';
      }
    } finally {
      saving = false;
    }
  }
</script>

<div class="space-y-6">
  <div>
    <h2 class="mb-1 text-2xl font-semibold tracking-tight">Security</h2>
    <p class="m-0 text-sm text-[var(--muted-foreground)]">Change the password for your CLUB account. Every active browser session is signed out when you change your password.</p>
  </div>

  {#if error}
    <Alert class="border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_10%,var(--card))] text-[var(--destructive)]">
      {error}
    </Alert>
  {/if}

  {#if success}
    <Alert class="border-[var(--success)]/30 bg-[color:color-mix(in_srgb,var(--success)_10%,var(--card))] text-[var(--success)]">
      {success}
    </Alert>
  {/if}

  <Card class="max-w-2xl p-6">
    <form class="security-form space-y-5" onsubmit={changePassword}>
      <div class="space-y-2">
        <label for="current-password" class="block text-sm font-medium">Current password</label>
        <Input id="current-password" type="password" bind:value={currentPassword} autocomplete="current-password" placeholder="Enter your current password" />
      </div>

      <div class="space-y-2">
        <label for="new-password" class="block text-sm font-medium">New password</label>
        <Input id="new-password" type="password" bind:value={newPassword} autocomplete="new-password" placeholder="At least 8 characters" minlength={8} maxlength={256} />
        <p class="m-0 text-xs text-[var(--muted-foreground)]">
          Must be 8–256 characters. Use a unique password you don't use elsewhere.
        </p>
      </div>

      <div class="space-y-2">
        <label for="confirm-password" class="block text-sm font-medium">Confirm new password</label>
        <Input id="confirm-password" type="password" bind:value={confirmPassword} autocomplete="new-password" placeholder="Re-enter your new password" minlength={8} maxlength={256} />
      </div>

      <div class="flex justify-end">
        <Button type="submit" disabled={saving}>
          {saving ? 'Saving...' : 'Change password'}
        </Button>
      </div>
    </form>
  </Card>
</div>

<style>
  .security-form :global(input) {
    font-size: 0.875rem;
    line-height: 1.25rem;
  }
</style>
