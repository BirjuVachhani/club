<script lang="ts">
  import { page } from '$app/state';
  import type { Snippet } from 'svelte';

  interface Props {
    children: Snippet;
  }

  let { children }: Props = $props();

  const navItems = [
    { href: '/admin/settings/stats', label: 'Stats' },
    { href: '/admin/users', label: 'Users' },
    { href: '/admin/packages', label: 'Packages' },
    { href: '/admin/publishers', label: 'Publishers' },
    { href: '/admin/settings/sdk', label: 'Scoring' },
    { href: '/admin/settings/legal', label: 'Legal' },
    { href: '/admin/settings/ownership', label: 'Ownership' },
  ];

  function isActive(href: string): boolean {
    const path = page.url.pathname;
    if (path === href) return true;
    if (path.startsWith(href + '/')) return true;
    return false;
  }
</script>

<div class="flex w-full flex-col gap-4 lg:grid lg:grid-cols-[220px_minmax(0,1fr)] lg:gap-10">
  <aside class="admin-aside h-fit rounded-xl border border-[var(--border)] bg-[var(--card)] p-2 shadow-sm lg:p-3">
    <div class="hidden border-b border-[var(--border)] px-3 pb-3 lg:block">
      <h1 class="m-0 text-lg font-semibold">Admin</h1>
    </div>

    <nav class="nav-scroll flex gap-1 overflow-x-auto lg:mt-3 lg:flex-col lg:overflow-visible">
      {#each navItems as item (item.href)}
        <a
          href={item.href}
          class:active={isActive(item.href)}
          class="shrink-0 whitespace-nowrap rounded-lg px-3 py-2 text-sm font-medium transition-colors lg:shrink lg:whitespace-normal"
        >
          {item.label}
        </a>
      {/each}
    </nav>
  </aside>

  <section class="min-w-0">
    {@render children()}
  </section>
</div>

<style>
  nav a {
    color: var(--foreground);
    background: transparent;
    text-decoration: none;
  }

  nav a:hover {
    background: var(--accent);
    color: var(--accent-foreground);
  }

  nav a.active {
    background: var(--secondary);
    color: var(--primary);
    box-shadow: inset 0 0 0 1px var(--border);
  }

  .nav-scroll {
    scrollbar-width: thin;
    -webkit-overflow-scrolling: touch;
  }
  .nav-scroll::-webkit-scrollbar { height: 0; }
</style>
