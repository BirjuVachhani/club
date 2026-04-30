<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { api, ApiError } from '$lib/api/client';
  import { auth, type UserRole } from '$lib/stores/auth';

  let email = $state('');
  let displayName = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  let error = $state('');
  let loading = $state(false);

  // Pulled from the root layout via /api/setup/status. When false, the
  // server will return 403 anyway, but we short-circuit on the client to
  // avoid exposing the form at all.
  let signupEnabled = $derived((page.data as any)?.signupEnabled ?? false);

  async function submit() {
    error = '';
    if (!email.trim() || !displayName.trim()) {
      error = 'Email and display name are required.';
      return;
    }
    if (password.length < 8) {
      error = 'Password must be at least 8 characters.';
      return;
    }
    if (password !== confirmPassword) {
      error = 'Passwords do not match.';
      return;
    }

    loading = true;
    try {
      // Signup is deliberately opaque: the server returns {status:'ok'}
      // whether the email was fresh or already taken. The actual success
      // signal is whether /api/auth/login accepts the same credentials.
      await api.post<{ status: string }>('/api/auth/signup', {
        email: email.trim(),
        displayName: displayName.trim(),
        password
      });

      const login = await api.post<{
        userId: string;
        email: string;
        displayName: string;
        role: UserRole;
        isAdmin: boolean;
        mustChangePassword: boolean;
        avatarUrl: string | null;
      }>('/api/auth/login', { email: email.trim(), password });

      auth.login({
        id: login.userId,
        email: login.email,
        name: login.displayName,
        role: login.role,
        isAdmin: login.isAdmin ?? false,
        mustChangePassword: login.mustChangePassword,
        avatarUrl: login.avatarUrl ?? null
      });
      goto('/packages', { replaceState: true });
    } catch (e) {
      if (e instanceof ApiError) {
        // Either the signup payload was rejected (weak password etc.)
        // or the follow-up login failed (email already taken with a
        // different password). Show a generic message in the 401 case
        // so we don't inadvertently re-introduce enumeration.
        if (e.status === 401) {
          error = 'Could not sign you in. If this email is already registered, try the login page.';
        } else {
          const body = e.body as { error?: { message?: string } } | undefined;
          error = body?.error?.message ?? 'Signup failed.';
        }
      } else {
        error = 'Something went wrong. Please try again.';
      }
    } finally {
      loading = false;
    }
  }
</script>

<svelte:head><title>Sign up | CLUB</title></svelte:head>

<div class="page">
  <div class="card">
    <div class="brand">
      <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo" />
    </div>

    {#if !signupEnabled}
      <h1>Signup is disabled</h1>
      <p class="subtitle">
        This CLUB server doesn't accept public signups. Ask an admin to
        create an account for you, or
        <a href="/login">sign in</a> if you already have one.
      </p>
    {:else}
      <h1>Create your account</h1>
      <p class="subtitle">Join this CLUB server as a member.</p>

      <form onsubmit={(e) => { e.preventDefault(); submit(); }}>
        <label>
          <span>Email</span>
          <input type="email" bind:value={email} required autocomplete="email" />
        </label>
        <label>
          <span>Display name</span>
          <input type="text" bind:value={displayName} required autocomplete="name" />
        </label>
        <label>
          <span>Password (at least 8 chars)</span>
          <input type="password" bind:value={password} minlength="8" required autocomplete="new-password" />
        </label>
        <label>
          <span>Confirm password</span>
          <input type="password" bind:value={confirmPassword} minlength="8" required autocomplete="new-password" />
        </label>
        {#if error}<p class="error">{error}</p>{/if}
        <button type="submit" disabled={loading}>
          {loading ? 'Creating account...' : 'Create account'}
        </button>
      </form>

      <p class="footer">
        Already have an account? <a href="/login">Sign in</a>
      </p>
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
  .footer {
    margin: 1.5rem 0 0;
    text-align: center;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
  }
  .footer a { color: var(--primary); text-decoration: none; }
</style>
