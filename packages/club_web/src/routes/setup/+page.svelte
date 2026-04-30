<script lang="ts">
  import { goto } from '$app/navigation';
  import { auth } from '$lib/stores/auth';

  type Step = 'verify' | 'password';

  let step = $state<Step>('verify');
  let email = $state('');
  let code = $state('');
  let displayName = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  let error = $state('');
  let loading = $state(false);

  async function submitVerify() {
    error = '';
    if (!email.trim() || !email.includes('@')) {
      error = 'Enter a valid email address.';
      return;
    }
    // Normalize the code: server generates uppercase-only from a 31-char
    // alphabet, so anything else was a typo/paste-artifact. Upper-casing
    // here keeps the comparison on the server strict without annoying
    // the user.
    const normalizedCode = code.trim().toUpperCase();
    if (normalizedCode.length !== 12) {
      error = 'Setup code should be 12 characters.';
      return;
    }

    loading = true;
    try {
      const res = await fetch('/api/setup/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        body: JSON.stringify({ email: email.trim(), code: normalizedCode }),
      });
      const data = await res.json();
      if (!res.ok) {
        error = data.error?.message ?? 'Verification failed.';
        return;
      }
      step = 'password';
    } catch {
      error = 'Connection failed.';
    } finally {
      loading = false;
    }
  }

  async function submitPassword() {
    error = '';
    if (!displayName.trim()) {
      error = 'Enter your name.';
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
      const res = await fetch('/api/setup/complete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        body: JSON.stringify({
          email: email.trim(),
          displayName: displayName.trim(),
          password,
          confirmPassword,
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        error = data.error?.message ?? 'Failed to create account.';
        return;
      }

      // Setup doesn't issue a session — run the real login flow so the
      // server sets the HttpOnly session cookie just like any other login.
      const loginRes = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
        body: JSON.stringify({ email: email.trim(), password }),
      });
      const loginData = await loginRes.json();
      if (!loginRes.ok) {
        error = loginData.error?.message ?? 'Account created, but sign-in failed. Try logging in.';
        return;
      }
      // Session cookie is set by the login response; we just mirror the
      // user data locally so the UI can render without calling /me again.
      auth.login({
        id: loginData.userId ?? data.userId ?? '',
        email: loginData.email ?? data.email ?? '',
        name: loginData.displayName ?? data.displayName ?? displayName.trim(),
        role: loginData.role ?? data.role ?? 'owner',
        isAdmin: loginData.isAdmin ?? true,
        mustChangePassword: loginData.mustChangePassword ?? false,
        avatarUrl: loginData.avatarUrl ?? null,
      });
      await goto('/');
    } catch {
      error = 'Connection failed.';
    } finally {
      loading = false;
    }
  }
</script>

<div class="setup-page">
  <div class="setup-card">
    <div class="logo">
      <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo logo-full" />
    </div>

    {#if step === 'verify'}
      <h2>Setup</h2>
      <p class="subtitle">Create your admin account. The setup code is in the server logs.</p>

      <form onsubmit={(e) => { e.preventDefault(); submitVerify(); }}>
        <label>
          <span>Admin email</span>
          <input type="email" bind:value={email} placeholder="admin@example.com" required />
        </label>
        <label>
          <span>Setup code</span>
          <input
            type="text"
            bind:value={code}
            placeholder="XXXXXXXXXXXX"
            maxlength="12"
            minlength="12"
            autocomplete="one-time-code"
            autocapitalize="characters"
            spellcheck="false"
            class="code-input"
          />
        </label>
        {#if error}<p class="error">{error}</p>{/if}
        <button type="submit" disabled={loading}>{loading ? 'Verifying...' : 'Continue'}</button>
      </form>

    {:else if step === 'password'}
      <h2>Create your account</h2>
      <p class="subtitle">Set up your profile for <strong>{email}</strong>.</p>

      <form onsubmit={(e) => { e.preventDefault(); submitPassword(); }}>
        <label>
          <span>Your name</span>
          <input type="text" bind:value={displayName} placeholder="Jane Doe" autocomplete="name" required />
        </label>
        <label>
          <span>Password</span>
          <input type="password" bind:value={password} placeholder="Min 8 characters" minlength="8" required />
        </label>
        <label>
          <span>Confirm password</span>
          <input type="password" bind:value={confirmPassword} placeholder="Confirm" minlength="8" required />
        </label>
        {#if error}<p class="error">{error}</p>{/if}
        <button type="submit" disabled={loading}>{loading ? 'Creating...' : 'Create Account'}</button>
      </form>
    {/if}

    <div class="steps">
      <span class="dot" class:active={step === 'verify'}></span>
      <span class="dot" class:active={step === 'password'}></span>
    </div>
  </div>
</div>

<style>
  .setup-page {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--pub-default-background);
    overflow: auto;
    padding: 1rem;
  }

  .setup-card {
    width: 100%;
    max-width: 400px;
    padding: 1.5rem;
    border-radius: 12px;
    background: var(--pub-card-background);
    border: 1px solid var(--pub-card-border);
  }
  @media (min-width: 640px) {
    .setup-card { padding: 2.5rem; }
  }

  .logo {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    margin-bottom: 1.75rem;
  }
  .logo-full {
    height: 1.75rem;
    width: auto;
  }

  h2 {
    font-size: 1.2rem;
    font-weight: 600;
    margin: 0 0 0.25rem;
    color: var(--pub-heading-text-color);
    font-family: var(--pub-heading-font-family);
  }

  .subtitle {
    color: var(--pub-muted-text-color);
    font-size: 0.8125rem;
    margin: 0 0 1.25rem;
    line-height: 1.5;
  }

  form { display: flex; flex-direction: column; gap: 0.875rem; }

  label { display: flex; flex-direction: column; gap: 0.3rem; }
  label span { font-size: 0.75rem; font-weight: 500; color: var(--pub-muted-text-color); }

  input {
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--pub-input-border);
    border-radius: 6px;
    background: var(--pub-input-background);
    color: var(--pub-default-text-color);
    font-size: 0.875rem;
    font-family: inherit;
    outline: none;
    transition: border-color 0.15s ease;
  }
  input:focus { border-color: var(--pub-link-text-color); }
  input::placeholder { color: var(--pub-muted-text-color); opacity: 0.6; }

  .code-input {
    font-family: var(--pub-code-font-family);
    font-size: 0.9375rem;
    text-align: center;
    letter-spacing: 0.3em;
  }

  button {
    padding: 0.625rem 1rem;
    border: none;
    border-radius: 6px;
    background: var(--primary);
    color: var(--primary-foreground);
    font-size: 0.875rem;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
    transition: opacity 0.15s ease;
    margin-top: 0.25rem;
  }
  button:hover:not(:disabled) { opacity: 0.85; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }

  .error { color: var(--pub-error-color); font-size: 0.75rem; margin: 0; }

  .steps {
    display: flex;
    justify-content: center;
    gap: 0.375rem;
    margin-top: 1.5rem;
  }
  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--pub-divider-color);
    transition: background 0.2s ease;
  }
  .dot.active { background: var(--primary); }
</style>
