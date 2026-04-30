<script lang="ts">
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { api, ApiError } from '$lib/api/client';
  import Alert from '$lib/components/ui/Alert.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Card from '$lib/components/ui/Card.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { auth } from '$lib/stores/auth';

  let email = $state('');
  let password = $state('');
  let error = $state('');
  let loading = $state(false);
  let formEl = $state<HTMLFormElement | null>(null);

  // Enter should submit — but only when both fields are filled, so we
  // don't fire spurious requests on an incomplete form. `requestSubmit`
  // (not `submit`) runs the form's submit handler and native constraint
  // validation, so `required` keeps the guard honest for keyboard users.
  function handleKeydown(e: KeyboardEvent) {
    if (e.key !== 'Enter') return;
    if (!email.trim() || !password) return;
    e.preventDefault();
    formEl?.requestSubmit();
  }
  // Surfaced by the root layout from /api/setup/status. When true, show
  // the "Create account" link below the form.
  let signupEnabled = $derived((page.data as any)?.signupEnabled ?? false);

  // Only accept same-origin paths as redirects to avoid open-redirect abuse.
  // The param survives across OAuth's login → consent handoff.
  function safeRedirect(): string | null {
    const raw = page.url.searchParams.get('redirect');
    if (!raw) return null;
    if (!raw.startsWith('/') || raw.startsWith('//')) return null;
    if (raw.startsWith('/login')) return null;
    return raw;
  }

  async function handleSubmit(e: Event) {
    e.preventDefault();
    error = '';
    loading = true;

    try {
      const response = await api.post<{
        userId: string;
        email: string;
        displayName: string;
        role: import('$lib/stores/auth').UserRole;
        isAdmin: boolean;
        mustChangePassword: boolean;
        avatarUrl: string | null;
      }>('/api/auth/login', { email, password });

      // Session + CSRF cookies are now set by the server. The store
      // mirrors the user info so the UI can render without re-fetching.
      auth.login({
        id: response.userId,
        email: response.email,
        name: response.displayName,
        role: response.role,
        isAdmin: response.isAdmin,
        mustChangePassword: response.mustChangePassword,
        avatarUrl: response.avatarUrl ?? null
      });
      // When a new password is mandatory, the root layout's guard will
      // route us to /welcome anyway — go directly to avoid a flash of the
      // packages page. Otherwise honor ?redirect= so flows like OAuth
      // consent can resume after auth.
      const next = response.mustChangePassword
        ? '/welcome'
        : (safeRedirect() ?? '/packages');
      goto(next, { replaceState: true });
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { message?: string } | undefined;
        error = body?.message ?? 'Invalid email or password.';
      } else {
        error = 'Something went wrong. Please try again.';
      }
    } finally {
      loading = false;
    }
  }
</script>

<div class="flex min-h-[70vh] w-full items-center justify-center px-4 py-8 sm:px-6">
  <Card class="w-full max-w-md p-6 sm:p-8">
    <div class="mb-6 text-center">
      <div class="mb-4 flex items-center justify-center">
        <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo" style="height: 28px; width: auto;" />
      </div>
      <h1 class="mb-2 text-xl font-semibold tracking-tight">Sign in</h1>
      <p class="m-0 text-sm text-[var(--muted-foreground)]">Use your account to manage packages, tokens, and publishers.</p>
    </div>

    {#if error}
      <Alert class="mb-4 border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_12%,var(--card))] text-[var(--destructive)]">
        {error}
      </Alert>
    {/if}

    <form bind:this={formEl} onsubmit={handleSubmit} class="space-y-4">
      <div class="space-y-2">
        <label for="email" class="block text-sm font-medium text-[var(--foreground)]">Email</label>
        <Input
          id="email"
          type="email"
          bind:value={email}
          placeholder="you@example.com"
          required
          autocomplete="email"
          onkeydown={handleKeydown}
        />
      </div>

      <div class="space-y-2">
        <label for="password" class="block text-sm font-medium text-[var(--foreground)]">Password</label>
        <Input
          id="password"
          type="password"
          bind:value={password}
          placeholder="Password"
          required
          autocomplete="current-password"
          onkeydown={handleKeydown}
        />
      </div>

      <Button type="submit" class="mt-2 w-full" size="lg" disabled={loading}>
        {loading ? 'Signing in...' : 'Sign in'}
      </Button>
    </form>

    {#if signupEnabled}
      <p class="mt-4 text-center text-sm text-[var(--muted-foreground)]">
        Don't have an account?
        <a href="/signup" class="font-medium text-[var(--primary)] hover:underline">
          Create one
        </a>
      </p>
    {/if}
  </Card>
</div>
