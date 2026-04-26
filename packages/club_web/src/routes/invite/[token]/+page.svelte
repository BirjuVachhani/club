<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { onMount } from 'svelte';
  import { api, ApiError } from '$lib/api/client';
  import { auth, type UserRole } from '$lib/stores/auth';

  let token = $derived(page.params.token);

  let email = $state('');
  let displayName = $state('');
  let expiresAt = $state<string | null>(null);

  let password = $state('');
  let confirmPassword = $state('');
  let loadError = $state('');
  let submitError = $state('');
  let loading = $state(true);
  let submitting = $state(false);

  onMount(async () => {
    try {
      const res = await api.get<{
        email: string;
        displayName: string;
        expiresAt: string;
      }>(`/api/invites/${token}`);
      email = res.email;
      displayName = res.displayName;
      expiresAt = res.expiresAt;
    } catch (e) {
      if (e instanceof ApiError) {
        const body = e.body as { error?: { message?: string } } | undefined;
        loadError = body?.error?.message ?? 'Invalid or expired invite link.';
      } else {
        loadError = 'Failed to load invite.';
      }
    } finally {
      loading = false;
    }
  });

  async function submit() {
    submitError = '';
    if (password.length < 8) {
      submitError = 'Password must be at least 8 characters.';
      return;
    }
    if (password !== confirmPassword) {
      submitError = 'Passwords do not match.';
      return;
    }

    submitting = true;
    try {
      await api.post<{
        userId: string;
        email: string;
        displayName: string;
        role: UserRole;
        mustChangePassword: boolean;
      }>(`/api/invites/${token}/accept`, { password });

      // Invite-accept doesn't set a session — run /api/auth/login so the
      // server issues the HttpOnly session cookie.
      const login = await api.post<{
        userId: string;
        email: string;
        displayName: string;
        role: UserRole;
        isAdmin: boolean;
        mustChangePassword: boolean;
        avatarUrl: string | null;
      }>('/api/auth/login', { email, password });

      auth.login({
        id: login.userId,
        email: login.email,
        name: login.displayName,
        role: login.role,
        isAdmin: login.isAdmin ?? (login.role === 'owner' || login.role === 'admin'),
        mustChangePassword: login.mustChangePassword,
        avatarUrl: login.avatarUrl ?? null
      });
      goto('/packages', { replaceState: true });
    } catch (e) {
      if (e instanceof ApiError) {
        const body = e.body as { error?: { message?: string } } | undefined;
        submitError = body?.error?.message ?? 'Failed to accept invite.';
      } else {
        submitError = 'Something went wrong. Please try again.';
      }
    } finally {
      submitting = false;
    }
  }
</script>

<svelte:head><title>Accept invite | CLUB</title></svelte:head>

<div class="page">
  <div class="card">
    <div class="brand">
      <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo" />
    </div>

    {#if loading}
      <p class="subtitle">Loading invite…</p>
    {:else if loadError}
      <h1>Invite link problem</h1>
      <p class="error">{loadError}</p>
      <p class="subtitle">Ask your admin for a new invite.</p>
    {:else}
      <h1>Welcome, {displayName}</h1>
      <p class="subtitle">
        Set a password to activate your account (<code>{email}</code>).
      </p>

      <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
        <label>
          <span>Password (at least 8 chars)</span>
          <input type="password" bind:value={password} minlength="8" required autocomplete="new-password" />
        </label>
        <label>
          <span>Confirm password</span>
          <input type="password" bind:value={confirmPassword} minlength="8" required autocomplete="new-password" />
        </label>
        {#if submitError}<p class="error">{submitError}</p>{/if}
        <button type="submit" disabled={submitting}>
          {submitting ? 'Setting password...' : 'Set password and sign in'}
        </button>
      </form>

      {#if expiresAt}
        <p class="footer">Link expires {new Date(expiresAt).toLocaleString()}.</p>
      {/if}
    {/if}
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
  .brand {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    margin-bottom: 1.5rem;
  }
  .brand-full-logo { height: 28px; width: auto; }
  h1 {
    margin: 0 0 0.5rem;
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--foreground);
    text-align: center;
  }
  .subtitle {
    margin: 0 0 1.5rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    text-align: center;
  }
  .subtitle code {
    font-family: var(--pub-code-font-family);
    font-size: 0.8125rem;
    color: var(--foreground);
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
  .error {
    margin: 0;
    color: var(--destructive);
    font-size: 0.8125rem;
  }
  .footer {
    margin: 1.5rem 0 0;
    text-align: center;
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }
</style>
