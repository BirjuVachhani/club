<script lang="ts">
  /**
   * Horizontal tab bar patterned after pub.dev's package/publisher
   * detail pages. Renders as a strip of links — clicking navigates,
   * so every tab is a real URL and deep-linkable.
   *
   * Pass a list of `{label, href}` and the current pathname. The
   * active tab is the one whose `href` is a prefix of the current
   * path (so `/packages/foo/admin` highlights the `admin` tab even
   * if the URL has a subpath).
   */
  interface Tab {
    label: string;
    href: string;
    /** When true the tab is hidden from the bar entirely. */
    hidden?: boolean;
  }

  interface Props {
    tabs: Tab[];
    pathname: string;
  }

  let { tabs, pathname }: Props = $props();

  const visible = $derived(tabs.filter((t) => !t.hidden));

  // Pick the single best-matching tab: exact match wins, otherwise the
  // tab whose href is the longest prefix of the current path. Without
  // the "longest" rule a sibling tab at `/x` would also light up when
  // viewing `/x/y`, because both `/x` and `/x/y` start with `/x/`.
  const activeHref = $derived.by(() => {
    let best: Tab | null = null;
    for (const t of visible) {
      if (t.href === pathname) return t.href;
      if (pathname.startsWith(t.href + '/')) {
        if (!best || t.href.length > best.href.length) best = t;
      }
    }
    return best?.href ?? null;
  });

  function isActive(tab: Tab): boolean {
    return tab.href === activeHref;
  }
</script>

<nav class="tabs" aria-label="Page sections">
  {#each visible as tab (tab.href)}
    <a
      href={tab.href}
      class="tab"
      class:active={isActive(tab)}
      aria-current={isActive(tab) ? 'page' : undefined}
    >
      {tab.label}
    </a>
  {/each}
</nav>

<style>
  .tabs {
    display: flex;
    gap: 0.25rem;
    border-bottom: 1px solid var(--border);
    margin-bottom: 1.5rem;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .tabs::-webkit-scrollbar {
    display: none;
  }

  .tab {
    padding: 0.75rem 1rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    font-weight: 500;
    text-decoration: none;
    border-bottom: 2px solid transparent;
    margin-bottom: -1px;
    transition: color 0.12s ease, border-color 0.12s ease;
    white-space: nowrap;
  }

  .tab:hover {
    color: var(--foreground);
  }

  .tab.active {
    color: var(--primary);
    border-bottom-color: var(--primary);
  }
</style>
