<script lang="ts">
  import { goto } from "$app/navigation";
  import { docsUrl } from "$lib/config";
  import DotsGrid from "$lib/components/DotsGrid.svelte";
  import Skeleton from "$lib/components/Skeleton.svelte";
  import type { HomePackage } from "./+page";

  let { data } = $props();

  let searchQuery = $state("");

  // Fixed-length range for rendering skeleton placeholder cards.
  const skeletonRange = Array.from({ length: 6 }, (_, i) => i);

  // Halo params scale per breakpoint. On narrow/portrait viewports the
  // halo has to be larger and higher to clear the hero content; on
  // desktop the original values look right.
  type Halo = { radius: number; y: number };
  const HALO = {
    mobile: { radius: 0.55, y: 0.5 } satisfies Halo,
    tablet: { radius: 0.42, y: 0.55 } satisfies Halo,
    desktop: { radius: 0.35, y: 0.65 } satisfies Halo,
  };

  let halo = $state<Halo>(HALO.desktop);

  $effect(() => {
    if (typeof window === "undefined") return;
    const mq = {
      mobile: window.matchMedia("(max-width: 767px)"),
      tablet: window.matchMedia("(min-width: 768px) and (max-width: 1023px)"),
    };
    function update() {
      halo = mq.mobile.matches
        ? HALO.mobile
        : mq.tablet.matches
          ? HALO.tablet
          : HALO.desktop;
    }
    update();
    mq.mobile.addEventListener("change", update);
    mq.tablet.addEventListener("change", update);
    return () => {
      mq.mobile.removeEventListener("change", update);
      mq.tablet.removeEventListener("change", update);
    };
  });

  function handleSearch(e: Event) {
    e.preventDefault();
    if (searchQuery.trim()) {
      goto(`/packages?q=${encodeURIComponent(searchQuery)}&page=1`);
    } else {
      goto("/packages");
    }
  }

  function timeAgo(dateStr: string | null): string {
    if (!dateStr) return "";
    const diff = Date.now() - new Date(dateStr).getTime();
    const days = Math.floor(diff / 86400000);
    if (days === 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 30) return `${days} days ago`;
    if (days < 365) return `${Math.floor(days / 30)} months ago`;
    return `${Math.floor(days / 365)} years ago`;
  }
</script>

<svelte:head><title>CLUB — Private Dart Package Repository</title></svelte:head>

{#snippet pkgCard(pkg: HomePackage, prefix: string)}
  <a href="/packages/{pkg.name}" class="home-card">
    <div class="home-card-top">
      <span class="home-card-name">{pkg.name}</span>
    </div>
    <p class="home-card-desc">{pkg.description}</p>
    {#if pkg.publishedAt || pkg.version}
      <div class="home-card-footer">
        {#if pkg.publishedAt}
          <span class="home-card-meta">{prefix}{timeAgo(pkg.publishedAt)}</span>
        {:else}
          <span></span>
        {/if}
        {#if pkg.version}
          <span class="home-card-version">v{pkg.version}</span>
        {/if}
      </div>
    {/if}
  </a>
{/snippet}

{#snippet pkgSection(
  title: string,
  href: string,
  items: HomePackage[],
  prefix: string,
)}
  {#if items.length > 0}
    <section class="pkg-section">
      <div class="section-header">
        <h2>{title}</h2>
        <a {href} class="view-all">View all &rarr;</a>
      </div>
      <div class="pkg-grid">
        {#each items as pkg}
          {@render pkgCard(pkg, prefix)}
        {/each}
      </div>
    </section>
  {/if}
{/snippet}

{#snippet skeletonSection(title: string)}
  <section class="pkg-section">
    <div class="section-header">
      <h2>{title}</h2>
    </div>
    <div class="pkg-grid">
      {#each skeletonRange as i (i)}
        <div class="home-card">
          <Skeleton width="42%" height="16px" radius="5px" />
          <div class="skeleton-desc">
            <Skeleton width="100%" height="11px" radius="4px" />
            <Skeleton width="88%" height="11px" radius="4px" />
            <Skeleton width="60%" height="11px" radius="4px" />
          </div>
          <div class="home-card-footer">
            <Skeleton width="38%" height="11px" radius="4px" />
            <Skeleton width="38px" height="11px" radius="4px" />
          </div>
        </div>
      {/each}
    </div>
  </section>
{/snippet}

<div class="home">
  <!-- Hero Section -->
  <section class="hero">
    <DotsGrid centerHoleRadius={halo.radius} centerHoleY={halo.y} />
    <div class="hero-content">
      <div class="hero-lockup">
        <img
          src="/club_full_logo.svg"
          alt="CLUB"
          class="hero-full-logo brand-full-logo"
        />
      </div>
      <form class="hero-search" onsubmit={handleSearch}>
        <svg
          class="hero-search-icon"
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
        >
          <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
        </svg>
        <input
          type="text"
          bind:value={searchQuery}
          placeholder="Search packages"
        />
      </form>
      <p class="hero-sub">Your private Dart & Flutter package repository</p>
      {#await data.streamed.home then home}
        {#if home.totalPackages > 0}
          <p class="hero-stat">
            {home.totalPackages}
            {home.totalPackages === 1 ? "package" : "packages"} hosted
          </p>
        {/if}
      {/await}
      <a href="/packages" class="hero-view-all">View all packages &rarr;</a>
    </div>
  </section>

  {#await data.streamed.home}
    <div class="sections">
      {@render skeletonSection("Dart packages")}
      {@render skeletonSection("Flutter packages")}
      {@render skeletonSection("Recently Updated")}
      {@render skeletonSection("Recently Added")}
    </div>
  {:then home}
    {#if home.totalPackages === 0}
      <div class="empty-state">
        <div class="empty-card">
          <h2>No packages yet</h2>
          <p>Publish your first Dart or Flutter package to get started.</p>
          <a
            class="empty-cta"
            href={docsUrl("/getting-started/first-package")}
            target="_blank"
            rel="noopener noreferrer"
          >
            Publish your first package
          </a>
          <a
            class="empty-secondary"
            href={docsUrl()}
            target="_blank"
            rel="noopener noreferrer"
          >
            View full documentation &rarr;
          </a>
        </div>
      </div>
    {/if}

    <!-- Package Sections -->
    <div class="sections">
      {@render pkgSection(
        "Dart packages",
        "/packages?sort=updated",
        home.dartPackages,
        "",
      )}
      {@render pkgSection(
        "Flutter packages",
        "/packages?sort=updated",
        home.flutterPackages,
        "",
      )}
      {@render pkgSection(
        "Recently Updated",
        "/packages?sort=updated",
        home.recentlyUpdated,
        "Updated ",
      )}
      {@render pkgSection(
        "Recently Added",
        "/packages?sort=created",
        home.recentlyAdded,
        "Added ",
      )}
    </div>
  {/await}
</div>

<style>
  .home {
    width: 100%;
  }

  /* ── Hero ── */
  .hero {
    position: relative;
    overflow: hidden;
    background: var(--background);
    margin-top: -56px;
    padding: 140px 16px 72px;
    text-align: center;
  }

  @media (min-width: 640px) {
    .hero {
      padding: 170px 24px 96px;
    }
  }

  @media (min-width: 768px) {
    .hero {
      padding: 200px 24px 120px;
    }
  }

  .hero-content {
    position: relative;
    z-index: 1;
    max-width: 600px;
    margin: 0 auto;
  }

  .hero-lockup {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 12px;
    margin: 0 auto 28px;
  }
  .hero-full-logo {
    display: block;
    height: 40px;
    width: auto;
    max-width: 100%;
  }
  @media (min-width: 640px) {
    .hero-full-logo { height: 56px; }
  }

  .hero-search {
    position: relative;
    max-width: 520px;
    margin: 0 auto 20px;
  }

  .hero-search-icon {
    position: absolute;
    left: 16px;
    top: 50%;
    transform: translateY(-50%);
    color: var(--muted-foreground);
    pointer-events: none;
    /* backdrop-filter on the input creates a stacking context that would
       otherwise paint over absolutely-positioned siblings. */
    z-index: 1;
  }

  .hero-search input {
    width: 100%;
    height: 48px;
    padding: 0 20px 0 44px;
    border: none;
    border-radius: 10px;
    background: color-mix(in srgb, var(--foreground) 8%, transparent);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    color: var(--foreground);
    font-size: 16px;
    font-family: inherit;
    outline: none;
    transition: background 0.2s;
  }

  .hero-search input::placeholder {
    color: var(--muted-foreground);
  }

  .hero-search input:focus {
    background: color-mix(in srgb, var(--foreground) 15%, transparent);
    box-shadow: 0 0 0 3px var(--ring);
  }

  .hero-sub {
    margin: 0 0 6px;
    color: var(--muted-foreground);
    font-size: 15px;
  }

  .hero-stat {
    margin: 0;
    color: var(--muted-foreground);
    opacity: 0.7;
    font-size: 13px;
  }

  .hero-view-all {
    display: inline-block;
    margin-top: 20px;
    padding: 10px 22px;
    border: 1px solid var(--primary);
    border-radius: 8px;
    color: var(--primary);
    font-size: 14px;
    font-weight: 600;
    text-decoration: none;
    transition:
      background 0.15s,
      color 0.15s;
  }
  .hero-view-all:hover {
    background: var(--primary);
    color: var(--primary-foreground);
  }

  /* ── Sections ── */
  .sections {
    max-width: 72rem;
    margin: 0 auto;
    padding: 32px 12px 20px;
  }

  @media (min-width: 640px) {
    .sections {
      padding: 40px 16px 20px;
    }
  }

  @media (min-width: 768px) {
    .sections {
      padding: 40px 24px 20px;
    }
  }

  .pkg-section {
    margin-bottom: 40px;
  }

  .section-header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    margin-bottom: 16px;
  }

  .section-header h2 {
    margin: 0;
    font-size: 20px;
    font-weight: 700;
    color: var(--pub-heading-text-color);
  }

  .view-all {
    font-size: 13px;
    font-weight: 600;
    color: var(--pub-link-text-color);
    text-decoration: none;
    white-space: nowrap;
  }

  .view-all:hover {
    text-decoration: underline;
  }

  /* ── Card Grid ── */
  .pkg-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(min(240px, 100%), 1fr));
    gap: 12px;
  }

  .home-card {
    display: flex;
    flex-direction: column;
    min-height: 210px;
    padding: 18px 20px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
    text-decoration: none;
    color: inherit;
    transition:
      border-color 0.15s,
      box-shadow 0.15s;
  }

  .home-card:hover {
    border-color: var(--pub-link-text-color);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06);
  }

  .home-card-top {
    display: flex;
    align-items: baseline;
    margin-bottom: 4px;
  }

  .home-card-name {
    font-size: 16px;
    font-weight: 600;
    color: var(--pub-link-text-color);
    overflow-wrap: anywhere;
    min-width: 0;
  }

  .home-card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    margin-top: auto;
  }

  .home-card-version {
    font-size: 11px;
    font-weight: 500;
    color: var(--pub-muted-text-color);
    font-family: var(--pub-code-font-family);
    white-space: nowrap;
  }

  .home-card-desc {
    margin: 0;
    font-size: 13px;
    line-height: 1.5;
    color: var(--pub-muted-text-color);
    flex: 1;
    overflow: hidden;
    -webkit-mask-image: linear-gradient(to bottom, black 60%, transparent 100%);
    mask-image: linear-gradient(to bottom, black 60%, transparent 100%);
  }

  .home-card-meta {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }
  .home-card-meta::before {
    content: "";
    width: 12px;
    height: 12px;
    flex-shrink: 0;
    background-color: currentColor;
    -webkit-mask: var(--clock-icon) center / contain no-repeat;
    mask: var(--clock-icon) center / contain no-repeat;
    --clock-icon: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='12' cy='12' r='9'/><polyline points='12 7 12 12 15.5 14'/></svg>");
  }

  /* Skeleton placeholder card — vertical rhythm between the stand-in
     description lines while the section streams in. */
  .skeleton-desc {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 12px;
  }

  /* ── Empty state ── */
  .empty-state {
    display: flex;
    justify-content: center;
    max-width: 72rem;
    margin: 0 auto;
    padding: 8px 16px 32px;
  }

  @media (min-width: 768px) {
    .empty-state {
      padding: 16px 24px 48px;
    }
  }

  .empty-card {
    width: 100%;
    max-width: 880px;
    padding: 40px 24px;
    border: 1px solid var(--border);
    border-radius: 16px;
    /* Explicit elevation so the card reads as a container regardless of
       whether --card happens to match --background in the active theme. */
    background: color-mix(in srgb, var(--foreground) 4%, var(--card));
    box-shadow:
      0 1px 3px rgba(0, 0, 0, 0.04),
      0 8px 24px rgba(0, 0, 0, 0.04);
    text-align: center;
  }

  .empty-card h2 {
    margin: 0 0 12px;
    font-size: 22px;
    font-weight: 700;
    color: var(--pub-heading-text-color);
  }
  @media (min-width: 640px) {
    .empty-card h2 { font-size: 28px; }
  }

  .empty-card p {
    margin: 0 0 28px;
    font-size: 16px;
    line-height: 1.5;
    color: var(--pub-muted-text-color);
  }

  .empty-cta {
    display: inline-block;
    padding: 12px 24px;
    border-radius: 10px;
    background: var(--primary);
    color: var(--primary-foreground);
    font-size: 15px;
    font-weight: 600;
    text-decoration: none;
    transition: opacity 0.15s ease;
  }

  .empty-cta:hover {
    opacity: 0.9;
  }

  .empty-secondary {
    display: block;
    margin-top: 14px;
    font-size: 13px;
    font-weight: 500;
    color: var(--pub-link-text-color);
    text-decoration: none;
    transition: opacity 0.15s ease;
  }

  .empty-secondary:hover {
    opacity: 0.75;
    text-decoration: underline;
  }
</style>
