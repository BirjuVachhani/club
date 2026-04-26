<script lang="ts">
  import '@fontsource-variable/inter';
  // Fira Code is used by `--pub-code-font-family` across pages. Bundling
  // it locally (rather than loading from Google Fonts) keeps the CSP
  // strict — no external `style-src` hosts needed.
  import '@fontsource/fira-code/400.css';
  import '@fontsource/fira-code/500.css';
  import '@fontsource/fira-code/600.css';
  import '../app.css';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { highlightCodeAction } from '$lib/actions/highlightCodeBlocks';
  import { api } from '$lib/api/client';
  import { auth, isAuthenticated, isAdmin } from '$lib/stores/auth';
  import { theme } from '$lib/stores/theme';
  import IntegrityAlertBar from '$lib/components/IntegrityAlertBar.svelte';
  import IntegrityDialog from '$lib/components/IntegrityDialog.svelte';
  import ConfirmHost from '$lib/components/ui/ConfirmHost.svelte';
  import { docsUrl, SITE_URL } from '$lib/config';
  import type { Snippet } from 'svelte';

  interface MissingVersion {
    package: string;
    version: string;
    publishedAt: string;
  }

  interface Props {
    children: Snippet;
  }

  let { children }: Props = $props();

  // Bare pages — no header, footer, or chrome
  const bareRoutes = ['/setup', '/login', '/oauth/consent'];
  let isBare = $derived(bareRoutes.some((r) => page.url.pathname.startsWith(r)));
  let isHome = $derived(page.url.pathname === '/');

  let currentTheme = $state<'light' | 'dark'>('light');

  $effect(() => {
    const unsub = theme.subscribe((t) => {
      currentTheme = t;
    });
    return unsub;
  });

  let headerDark = $derived(isHome && currentTheme === 'dark');

  let authenticated = $state(false);
  let userEmail = $state('');
  let userName = $state('');
  let userAvatarUrl = $state<string | null>(null);
  let menuOpen = $state(false);
  let userIsAdmin = $state(false);

  let missingVersions = $state<MissingVersion[]>([]);
  let integrityChecked = $state(false);
  let integrityDialogOpen = $state(false);

  $effect(() => {
    const unsub = isAuthenticated.subscribe((v) => {
      authenticated = v;
    });
    return unsub;
  });

  $effect(() => {
    const unsub = isAdmin.subscribe((v) => {
      userIsAdmin = v;
    });
    return unsub;
  });

  // Admins get an integrity probe on first auth: DB versions whose
  // tarballs are missing on disk. Result is surfaced as a persistent
  // alert bar above the header on every page until the entries are
  // resolved (no per-session dismiss — the alert is intentionally
  // sticky because stranded entries are a real data-integrity issue).
  $effect(() => {
    if (!userIsAdmin || integrityChecked) return;
    integrityChecked = true;

    api
      .get<{ missingVersions: MissingVersion[] }>('/api/admin/integrity')
      .then((data) => {
        missingVersions = data.missingVersions ?? [];
      })
      .catch(() => {
        // Silent: integrity check is advisory, not critical.
      });
  });

  function updateMissing(items: MissingVersion[]) {
    missingVersions = items;
    if (items.length === 0) integrityDialogOpen = false;
  }

  $effect(() => {
    const unsub = auth.subscribe((state) => {
      userEmail = state.user?.email ?? '';
      userName = state.user?.name ?? '';
      userAvatarUrl = state.user?.avatarUrl ?? null;
    });
    return unsub;
  });

  // Global search
  let searchQuery = $state('');

  $effect(() => {
    const q = page.url.searchParams.get('q');
    searchQuery = q ?? '';
  });

  function handleSearch(e: Event) {
    e.preventDefault();
    goto(`/packages?q=${encodeURIComponent(searchQuery)}&page=1`);
  }

  function clickOutside(node: HTMLElement, handler: () => void) {
    function handleClick(e: MouseEvent) {
      if (!node.contains(e.target as Node)) handler();
    }
    document.addEventListener('mousedown', handleClick, true);
    return { destroy() { document.removeEventListener('mousedown', handleClick, true); } };
  }

  function toggleTheme() {
    theme.toggle();
  }

  async function logout() {
    menuOpen = false;
    // Fire-and-forget: we still clear the client-side user and bounce
    // to /login even if the server call fails (e.g. session already
    // expired). The server endpoint is what clears the HttpOnly cookie.
    try {
      await api.post('/api/auth/logout');
    } catch {
      // Ignore — the next authenticated call would 401 anyway.
    }
    auth.logout();
    window.location.href = '/login';
  }

</script>

<ConfirmHost />

{#if isBare}
  <div use:highlightCodeAction>
    {@render children()}
  </div>
{:else}
  <div class="flex min-h-screen flex-col bg-[var(--background)]">
    {#if userIsAdmin && missingVersions.length > 0}
      <IntegrityAlertBar
        count={missingVersions.length}
        onReview={() => (integrityDialogOpen = true)}
      />
    {/if}
    <header class="z-100 {isHome ? 'bg-transparent' : 'border-b border-[var(--border)] bg-[var(--card)]'}">
      <div class="mx-auto flex h-14 w-full max-w-7xl items-center gap-2 px-3 sm:gap-4 sm:px-4 md:px-6">
        <!-- Logo (hidden on home page) -->
        {#if !isHome}
          <a href="/" class="flex shrink-0 items-center gap-2">
            <img src="/club_full_logo.svg" alt="CLUB" class="brand-full-logo h-6 w-auto" />
          </a>
        {/if}

        <!-- Left spacer (hidden on small screens to give search more room) -->
        <div class="hidden flex-1 md:block"></div>

        <!-- Search bar (hidden on home page) -->
        {#if !isHome}
          <form onsubmit={handleSearch} class="header-search">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
            </svg>
            <input
              type="text"
              bind:value={searchQuery}
              placeholder="Search packages"
              aria-label="Search packages"
            />
            <button type="submit" aria-label="Search">
              <span class="search-btn-label">Search</span>
              <svg class="search-btn-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/>
              </svg>
            </button>
          </form>
        {/if}

        <!-- Right spacer (hidden on small screens) -->
        <div class="hidden flex-1 md:block"></div>

        <!-- Right actions -->
        <div class="flex shrink-0 items-center gap-2">
          <button
            class="inline-flex h-9 w-9 sm:h-10 sm:w-10 items-center justify-center rounded-full {headerDark ? 'text-white/80 bg-black/40 backdrop-blur-md hover:bg-black/60 hover:text-white' : 'bg-[var(--secondary)] text-[var(--muted-foreground)] hover:bg-[var(--accent)] hover:text-[var(--accent-foreground)]'} transition-colors duration-200"
            onclick={toggleTheme}
            title="Toggle theme"
          >
            {#if currentTheme === 'light'}
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
              </svg>
            {:else}
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <circle cx="12" cy="12" r="5" />
                <line x1="12" y1="1" x2="12" y2="3" />
                <line x1="12" y1="21" x2="12" y2="23" />
                <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" />
                <line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                <line x1="1" y1="12" x2="3" y2="12" />
                <line x1="21" y1="12" x2="23" y2="12" />
                <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" />
                <line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
              </svg>
            {/if}
          </button>

          {#if authenticated}
            <div class="relative flex" use:clickOutside={() => menuOpen = false}>
              <button
                class="inline-flex h-9 w-9 sm:h-10 sm:w-10 items-center justify-center overflow-hidden rounded-full border text-sm font-medium transition-colors {headerDark ? 'border-white/15 bg-black/40 backdrop-blur-md text-white' : 'border-[var(--border)] bg-[var(--secondary)] text-[var(--secondary-foreground)]'}"
                onclick={() => menuOpen = !menuOpen}
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                title="Profile menu"
              >
                {#if userAvatarUrl}
                  <img src={userAvatarUrl} alt="Profile avatar" class="block h-full w-full object-cover" />
                {:else}
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
                    <circle cx="12" cy="7" r="4" />
                  </svg>
                {/if}
              </button>

              {#if menuOpen}
                <div class="absolute right-0 top-[calc(100%+0.5rem)] z-50 w-60 rounded-xl border border-[var(--border)] bg-[var(--card)] p-2 shadow-lg">
                  <div class="px-3 py-2">
                    <div class="truncate text-sm font-medium text-[var(--foreground)]">{userName || 'Account'}</div>
                    <div class="truncate text-xs text-[var(--muted-foreground)]">{userEmail}</div>
                  </div>
                  <div class="my-1 h-px bg-[var(--border)]"></div>
                  <a
                    href="/my-packages"
                    class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                    onclick={() => menuOpen = false}
                  >
                    My packages
                  </a>
                  <a
                    href="/my-publishers"
                    class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                    onclick={() => menuOpen = false}
                  >
                    My publishers
                  </a>
                  <a
                    href="/my-liked-packages"
                    class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                    onclick={() => menuOpen = false}
                  >
                    Liked packages
                  </a>
                  <a
                    href="/activity"
                    class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                    onclick={() => menuOpen = false}
                  >
                    Activity log
                  </a>
                  <div class="my-1 h-px bg-[var(--border)]"></div>
                  <a
                    href="/settings"
                    class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                    onclick={() => menuOpen = false}
                  >
                    Settings
                  </a>
                  {#if userIsAdmin}
                    <a
                      href="/admin/settings/stats"
                      class="block rounded-md px-3 py-2 text-sm text-[var(--foreground)] transition-colors hover:bg-[var(--accent)]"
                      onclick={() => menuOpen = false}
                    >
                      Admin
                    </a>
                  {/if}
                  <div class="my-1 h-px bg-[var(--border)]"></div>
                  <button
                    class="flex w-full items-center gap-2 rounded-md px-3 py-2 text-left text-sm text-[var(--destructive)] transition-colors hover:bg-[color:color-mix(in_srgb,var(--destructive)_8%,transparent)]"
                    onclick={logout}
                  >
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
                      <polyline points="16 17 21 12 16 7" />
                      <line x1="21" x2="9" y1="12" y2="12" />
                    </svg>
                    Logout
                  </button>
                </div>
              {/if}
            </div>
          {:else}
            <a href="/login" class="inline-flex h-9 items-center rounded-md border {headerDark ? 'border-white/20 text-white hover:bg-white/10' : 'border-[var(--border)] text-[var(--foreground)] hover:bg-[var(--accent)]'} px-3 sm:px-4 text-sm font-medium transition-colors">Sign In</a>
          {/if}
        </div>
      </div>
    </header>

    <IntegrityDialog
      open={integrityDialogOpen}
      items={missingVersions}
      onChange={updateMissing}
      onClose={() => (integrityDialogOpen = false)}
    />

    <main class="flex w-full flex-1 {isHome ? '' : 'mx-auto max-w-6xl px-4 py-5 sm:px-5 sm:py-6 md:px-6'}" use:highlightCodeAction>
      {@render children()}
    </main>

    <footer class="mt-auto border-t border-[var(--border)] bg-[var(--card)]">
      <div class="mx-auto flex w-full max-w-6xl flex-col items-start gap-3 px-4 py-4 text-sm text-[var(--muted-foreground)] sm:flex-row sm:items-center sm:justify-between sm:gap-4 sm:px-5 md:px-6">
        <span>Powered by <strong>CLUB</strong></span>
        <nav class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <a href={SITE_URL} target="_blank" rel="noopener noreferrer" class="hover:text-[var(--foreground)] transition-colors">About</a>
          <a href={docsUrl()} target="_blank" rel="noopener noreferrer" class="hover:text-[var(--foreground)] transition-colors">Docs</a>
          <a href="/privacy" class="hover:text-[var(--foreground)] transition-colors">Privacy</a>
          <a href="/terms" class="hover:text-[var(--foreground)] transition-colors">Terms</a>
        </nav>
      </div>
    </footer>
  </div>
{/if}

<style>
  .header-search {
    display: flex;
    align-items: center;
    flex: 1 1 auto;
    min-width: 0;
    max-width: 480px;
    height: 40px;
    border-radius: 8px;
    border: 1.5px solid var(--border);
    background: var(--background);
    padding: 0 0 0 12px;
    gap: 8px;
    overflow: hidden;
  }
  @media (min-width: 640px) {
    .header-search {
      padding-left: 14px;
      gap: 10px;
    }
  }
  .header-search svg {
    flex-shrink: 0;
    color: var(--muted-foreground);
  }
  .header-search input {
    flex: 1;
    min-width: 0;
    height: 100%;
    border: none;
    outline: none;
    background: transparent;
    font-family: inherit;
    font-size: 14px;
    color: var(--foreground);
    border-radius: 0;
    appearance: none;
    -webkit-appearance: none;
  }
  .header-search input::placeholder {
    color: var(--muted-foreground);
  }
  .header-search input:focus {
    outline: none;
    box-shadow: none;
  }
  .header-search button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    min-width: 44px;
    border: none;
    border-left: 1.5px solid var(--border);
    border-radius: 0;
    background: transparent;
    color: var(--foreground);
    font-family: inherit;
    font-size: 14px;
    font-weight: 600;
    padding: 0 14px;
    cursor: pointer;
    white-space: nowrap;
    transition: background 0.15s;
  }
  .header-search button:hover {
    background: var(--accent);
  }
  .header-search .search-btn-icon { display: inline-block; color: var(--muted-foreground); }
  .header-search .search-btn-label { display: none; }
  @media (min-width: 640px) {
    .header-search button { padding: 0 20px; }
    .header-search .search-btn-icon { display: none; }
    .header-search .search-btn-label { display: inline; }
  }
</style>
