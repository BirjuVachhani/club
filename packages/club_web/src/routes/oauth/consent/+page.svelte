<script lang="ts">
  import { browser } from '$app/environment';
  import { goto } from '$app/navigation';
  import { auth, isAuthenticated } from '$lib/stores/auth';
  import { api, ApiError } from '$lib/api/client';

  let requestId = $state('');
  let pendingInfo = $state<any>(null);
  let error = $state('');
  let loading = $state(false);
  let step = $state<'loading' | 'consent' | 'authorizing' | 'error'>('loading');

  let authenticated = $state(false);
  let userEmail = $state('');

  $effect(() => {
    const unsub = isAuthenticated.subscribe((v) => { authenticated = v; });
    return unsub;
  });

  $effect(() => {
    const unsub = auth.subscribe((s) => {
      if (s.user?.email) userEmail = s.user.email;
    });
    return unsub;
  });

  // Load pending auth info on mount
  $effect(() => {
    if (!browser) return;
    const params = new URLSearchParams(window.location.search);
    requestId = params.get('request_id') ?? '';

    if (!requestId) {
      error = 'Missing request_id parameter.';
      step = 'error';
      return;
    }

    loadPendingInfo();
  });

  async function loadPendingInfo() {
    // Auth first: the pending endpoint is now behind auth, so an
    // unauthenticated user would just see an opaque 401. Bouncing to
    // /login with a return path gives them the expected flow.
    if (!authenticated) {
      const here = window.location.pathname + window.location.search;
      window.location.replace(`/login?redirect=${encodeURIComponent(here)}`);
      return;
    }

    try {
      const res = await fetch(`/oauth/pending/${requestId}`, {
        credentials: 'include',
      });
      const data = await res.json();
      if (!res.ok) {
        error = data.error_description ?? 'Authorization request not found.';
        step = 'error';
        return;
      }
      pendingInfo = data;
      step = 'consent';
    } catch {
      error = 'Failed to load authorization request.';
      step = 'error';
    }
  }

  async function approve() {
    step = 'authorizing';
    loading = true;
    try {
      const res = await api.post<any>('/oauth/approve', {
        request_id: requestId,
      });

      const redirectUrl = res.redirect_url as string;

      // Per OAuth 2.0, hand off to the redirect_uri immediately. The client
      // (e.g. the CLI's local callback server) is responsible for rendering
      // the user-facing success page.
      window.location.replace(redirectUrl);
    } catch (e: any) {
      if (e instanceof ApiError) {
        const body = e.body as
          | { error?: { message?: string } | string; error_description?: string }
          | undefined;
        const serverMessage =
          (typeof body?.error === 'object' ? body?.error?.message : undefined) ??
          body?.error_description ??
          (typeof body?.error === 'string' ? body?.error : undefined);
        error = serverMessage ?? `${e.message}`;

        // 401 means our session is dead — clear it so the next attempt
        // forces a fresh login instead of replaying a bad token.
        if (e.status === 401) {
          auth.logout();
          authenticated = false;
        }
      } else {
        error = e?.message ?? 'Authorization failed.';
      }
      step = 'error';
      loading = false;
    }
  }

  function goHome() {
    goto('/');
  }

  function deny() {
    // Redirect back to CLI with access_denied error
    if (pendingInfo?.redirect_uri) {
      const uri = new URL(pendingInfo.redirect_uri);
      uri.searchParams.set('error', 'access_denied');
      uri.searchParams.set('error_description', 'User denied authorization.');
      if (pendingInfo.state) uri.searchParams.set('state', pendingInfo.state);
      window.location.href = uri.toString();
    } else {
      step = 'error';
      error = 'Authorization denied. You can close this tab.';
    }
  }

  function scopeLabel(scope: string): string[] {
    return scope.split(',').map((s) => {
      switch (s.trim()) {
        case 'read': return 'Read packages';
        case 'write': return 'Publish packages';
        case 'admin': return 'Admin access';
        default: return s.trim();
      }
    });
  }

</script>

<div class="oauth-page">
  <div class="oauth-card">
    <div class="logo">
      <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo logo-full" />
    </div>

    <!-- Loading -->
    {#if step === 'loading'}
      <div class="status-screen">
        <div class="spinner"></div>
        <p class="subtitle">Loading...</p>
      </div>

    <!-- Consent -->
    {:else if step === 'consent'}
      <div class="consent">
        <div class="consent-icon">
          <svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="var(--pub-link-text-color)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <rect x="2" y="3" width="20" height="18" rx="3" />
            <polyline points="7 10 10 13 7 16" />
            <line x1="13" y1="16" x2="17" y2="16" />
          </svg>
        </div>

        <h2>Authorize CLUB CLI</h2>

        <p class="consent-description">
          <strong>CLUB CLI</strong> is requesting permission to access your account.
        </p>

        <div class="account-badge">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="8" r="4" /><path d="M4 20c0-4 4-6 8-6s8 2 8 6" />
          </svg>
          <span>{userEmail}</span>
        </div>

        <div class="permissions">
          <div class="permissions-header">This will allow CLUB CLI to:</div>
          {#if pendingInfo}
            <ul class="permissions-list">
              {#each scopeLabel(pendingInfo.scope) as perm}
                <li>
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--pub-success-color)" stroke-width="2.5">
                    <polyline points="4 12 9 17 20 6" />
                  </svg>
                  <span>{perm}</span>
                </li>
              {/each}
              <li>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--pub-success-color)" stroke-width="2.5">
                  <polyline points="4 12 9 17 20 6" />
                </svg>
                <span>Create API tokens on your behalf</span>
              </li>
            </ul>
          {/if}
        </div>

        <div class="consent-note">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10" /><line x1="12" y1="8" x2="12" y2="12" /><line x1="12" y1="16" x2="12.01" y2="16" />
          </svg>
          <span>Authorizing will create a new API token. You can revoke it anytime from Settings.</span>
        </div>

        {#if error}<p class="error">{error}</p>{/if}

        <div class="consent-actions">
          <button class="btn-primary" onclick={approve} disabled={loading}>
            Authorize CLUB CLI
          </button>
          <button class="btn-deny" onclick={deny} disabled={loading}>
            Deny
          </button>
        </div>
      </div>

    <!-- Authorizing -->
    {:else if step === 'authorizing'}
      <div class="status-screen">
        <div class="spinner"></div>
        <h2>Authorizing...</h2>
        <p class="subtitle">Creating token and redirecting back to the CLI...</p>
      </div>

    <!-- Error -->
    {:else if step === 'error'}
      <div class="status-screen">
        <svg class="error-icon" width="56" height="56" viewBox="0 0 24 24" fill="none" stroke="var(--pub-error-color)" stroke-width="2">
          <circle cx="12" cy="12" r="10" />
          <line x1="15" y1="9" x2="9" y2="15" />
          <line x1="9" y1="9" x2="15" y2="15" />
        </svg>
        <h2>Authorization Failed</h2>
        <p class="error-text">{error}</p>
        <div class="error-actions">
          <button class="btn-secondary" onclick={() => { error = ''; loadPendingInfo(); }}>
            Try Again
          </button>
          <button class="btn-secondary" onclick={goHome}>
            Go Home
          </button>
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .oauth-page {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--pub-default-background);
    overflow: hidden;
  }

  .oauth-card {
    width: 100%;
    max-width: 440px;
    padding: 2.5rem;
    border-radius: 12px;
    background: var(--pub-card-background);
    border: 1px solid var(--pub-card-border);
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

  h2 { font-size: 1.15rem; font-weight: 600; margin: 0 0 0.25rem; color: var(--pub-heading-text-color); }
  .subtitle { color: var(--pub-muted-text-color); font-size: 0.8125rem; margin: 0 0 1.25rem; line-height: 1.5; }

  /* Consent screen */
  .consent { text-align: center; }
  .consent h2 { margin-top: 0.75rem; }
  .consent-icon { display: flex; justify-content: center; }

  .consent-description {
    color: var(--pub-muted-text-color);
    font-size: 0.875rem;
    margin: 0.5rem 0 1rem;
    line-height: 1.5;
  }

  .account-badge {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.375rem 0.75rem;
    border-radius: 20px;
    background: var(--pub-default-background);
    border: 1px solid var(--pub-divider-color);
    font-size: 0.8125rem;
    color: var(--pub-default-text-color);
    margin-bottom: 1.25rem;
  }

  .permissions {
    text-align: left;
    border: 1px solid var(--pub-divider-color);
    border-radius: 8px;
    padding: 0.875rem 1rem;
    margin-bottom: 1rem;
  }
  .permissions-header {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--pub-muted-text-color);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin-bottom: 0.625rem;
  }
  .permissions-list {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .permissions-list li {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8125rem;
    color: var(--pub-default-text-color);
  }

  .consent-note {
    display: flex;
    align-items: flex-start;
    gap: 0.5rem;
    font-size: 0.6875rem;
    color: var(--pub-muted-text-color);
    line-height: 1.4;
    margin-bottom: 1.25rem;
    text-align: left;
  }
  .consent-note svg { flex-shrink: 0; margin-top: 1px; }

  .consent-actions {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  /* Status screens */
  .status-screen { text-align: center; padding: 1rem 0; }
  .status-screen h2 { margin-top: 1rem; }
  .error-icon { display: block; margin: 0 auto; }

  .spinner {
    width: 40px;
    height: 40px;
    border: 3px solid var(--pub-divider-color);
    border-top-color: var(--pub-link-text-color);
    border-radius: 50%;
    margin: 0 auto;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* Buttons */
  .btn-primary {
    width: 100%;
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
  }
  .btn-primary:hover:not(:disabled) { opacity: 0.85; }
  .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; }

  .btn-deny {
    width: 100%;
    padding: 0.625rem 1rem;
    border: 1px solid var(--pub-divider-color);
    border-radius: 6px;
    background: transparent;
    color: var(--pub-muted-text-color);
    font-size: 0.8125rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    transition: color 0.15s ease;
  }
  .btn-deny:hover { color: var(--pub-error-color); }

  .btn-secondary {
    padding: 0.5rem 1.5rem;
    border: 1px solid var(--pub-divider-color);
    border-radius: 6px;
    background: transparent;
    color: var(--pub-default-text-color);
    font-size: 0.8125rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    margin-top: 1rem;
  }

  .error { color: var(--pub-error-color); font-size: 0.75rem; margin: 0.5rem 0 0; }
  .error-text { color: var(--pub-error-color); font-size: 0.8125rem; margin: 0.5rem 0 0; }

  .error-actions {
    display: flex;
    justify-content: center;
    gap: 0.5rem;
    margin-top: 1rem;
    flex-wrap: wrap;
  }
  .error-actions .btn-secondary { margin-top: 0; }
</style>
