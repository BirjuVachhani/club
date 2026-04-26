<script lang="ts">
  import { api, ApiError } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';

  let currentPassword = $state('');
  let newPassword = $state('');
  let confirmPassword = $state('');
  let error = $state('');
  let loading = $state(false);

  async function submit() {
    error = '';
    if (newPassword.length < 8) {
      error = 'New password must be at least 8 characters.';
      return;
    }
    if (newPassword !== confirmPassword) {
      error = 'Passwords do not match.';
      return;
    }

    loading = true;
    try {
      await api.post('/api/auth/change-password', {
        currentPassword,
        newPassword
      });
      // changePassword revokes every session, including the one that made
      // this call. Bounce through /login so the user gets a fresh cookie.
      auth.logout();
      window.location.href = '/login?redirect=/packages';
    } catch (e) {
      if (e instanceof ApiError) {
        const body = e.body as { error?: { message?: string } } | undefined;
        error = body?.error?.message ?? 'Failed to change password.';
      } else {
        error = 'Something went wrong. Please try again.';
      }
    } finally {
      loading = false;
    }
  }
</script>

<svelte:head><title>Welcome · Set your password | CLUB</title></svelte:head>

<div class="page">
  <div class="card">
    <img src="/club_logo.svg" alt="CLUB" class="logo brand-icon" />
    <h1>Welcome to CLUB</h1>
    <p class="subtitle">
      An admin created your account. Choose a new password to finish setup —
      you won't be able to use the app until you do.
    </p>

    <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
      <label>
        <span>Current (temporary) password</span>
        <input type="password" bind:value={currentPassword} required />
      </label>
      <label>
        <span>New password (at least 8 chars)</span>
        <input type="password" bind:value={newPassword} minlength="8" required />
      </label>
      <label>
        <span>Confirm new password</span>
        <input type="password" bind:value={confirmPassword} minlength="8" required />
      </label>
      {#if error}<p class="error">{error}</p>{/if}
      <button type="submit" disabled={loading}>
        {loading ? 'Setting password...' : 'Set password and continue'}
      </button>
    </form>
  </div>
</div>

<style>
  .page {
    min-height: 80vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.5rem 1rem;
  }
  @media (min-width: 640px) {
    .page { padding: 2rem; }
  }
  .card {
    width: 100%;
    max-width: 420px;
    padding: 1.5rem;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
  }
  @media (min-width: 640px) {
    .card { padding: 2.5rem; }
  }
  .logo { width: 40px; height: 40px; margin-bottom: 1rem; }
  h1 { margin: 0 0 0.5rem; font-size: 1.4rem; font-weight: 600; color: var(--foreground); }
  .subtitle {
    margin: 0 0 1.5rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    line-height: 1.5;
  }
  form { display: flex; flex-direction: column; gap: 0.875rem; }
  label { display: flex; flex-direction: column; gap: 0.35rem; }
  label span {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--muted-foreground);
  }
  input {
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--foreground);
    font-size: 0.875rem;
    outline: none;
  }
  input:focus { border-color: var(--primary); }
  button {
    padding: 0.625rem 1rem;
    margin-top: 0.5rem;
    background: var(--primary);
    color: var(--primary-foreground);
    border: none;
    border-radius: 6px;
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
  }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  .error { margin: 0; color: var(--destructive); font-size: 0.8125rem; }
</style>
