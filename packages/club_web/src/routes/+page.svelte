<script lang="ts">
  import GroupCard from "$lib/components/GroupCard.svelte";
  import { goto } from "$app/navigation";
  import { docsUrl } from "$lib/config";
  import Skeleton from "$lib/components/Skeleton.svelte";
  import type { HomePackage } from "./+page";

  let { data } = $props();

  let searchQuery = $state("");

  // Fixed-length range for rendering skeleton placeholder cards.
  const skeletonRange = Array.from({ length: 6 }, (_, i) => i);

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
    <div class="hero-background hero-background-light" aria-hidden="true">
      <img src="/bg_light.webp" alt="" />
    </div>
    <div class="hero-background hero-background-dark" aria-hidden="true">
      <img src="/bg_dark.webp" alt="" />
    </div>
    <div class="hero-bottom-fade" aria-hidden="true"></div>
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
      {#if home.groups.length}
        <section class="pkg-section">
          <div class="section-header">
            <h2>Package Groups</h2>
            <a href="/packages?type=groups">View all</a>
          </div>
          <div class="pkg-grid">
            {#each home.groups as group}<GroupCard {group} compact />{/each}
          </div>
        </section>
      {/if}
    </div>
  {/await}
</div>

<style>
  .home {
    width: 100%;
  }

  /* ── Hero ── */
  .hero {
    --hero-strong: #263442;
    --hero-text: #34495a;
    --hero-muted: #536b7c;
    --hero-search-surface: rgb(255 247 243 / 82%);
    --hero-search-focus: rgb(255 250 247 / 94%);
    position: relative;
    overflow: hidden;
    background: var(--background);
    transition: background-color 520ms cubic-bezier(0.22, 1, 0.36, 1);
    margin-top: -56px;
    padding: 140px 16px 72px;
    text-align: center;
  }

  :global(:root.dark-theme) .hero {
    --hero-strong: var(--foreground);
    --hero-text: var(--muted-foreground);
    --hero-muted: var(--muted-foreground);
    --hero-search-surface: color-mix(
      in srgb,
      var(--foreground) 8%,
      transparent
    );
    --hero-search-focus: color-mix(in srgb, var(--foreground) 15%, transparent);
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

  .hero-background {
    position: absolute;
    inset: 0;
    z-index: 0;
    display: block;
    width: 100%;
    height: 100%;
    pointer-events: none;
  }
  .hero-background img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
    object-position: center center;
  }
  .hero-background-light { opacity: 1; }
  .hero-background-dark { opacity: 0; }
  .hero-background-light,
  .hero-background-dark {
    transition: opacity 520ms cubic-bezier(0.22, 1, 0.36, 1);
    will-change: opacity;
  }
  :global(:root.dark-theme) .hero > .hero-background-light {
    opacity: 0;
  }
  :global(:root.dark-theme) .hero > .hero-background-dark {
    opacity: 1;
  }
  .hero-bottom-fade {
    position: absolute;
    right: 0;
    bottom: -1px;
    left: 0;
    z-index: 1;
    height: clamp(120px, 25%, 210px);
    background: linear-gradient(
      to bottom,
      transparent 0%,
      color-mix(in srgb, var(--background) 3%, transparent) 12%,
      color-mix(in srgb, var(--background) 8%, transparent) 22%,
      color-mix(in srgb, var(--background) 16%, transparent) 32%,
      color-mix(in srgb, var(--background) 27%, transparent) 43%,
      color-mix(in srgb, var(--background) 41%, transparent) 54%,
      color-mix(in srgb, var(--background) 57%, transparent) 65%,
      color-mix(in srgb, var(--background) 72%, transparent) 76%,
      color-mix(in srgb, var(--background) 85%, transparent) 86%,
      color-mix(in srgb, var(--background) 94%, transparent) 94%,
      var(--background) 100%
    );
    pointer-events: none;
  }

  @media (prefers-reduced-motion: reduce) {
    .hero,
    .hero-background-light,
    .hero-background-dark {
      transition: none;
    }
  }

  .hero-content {
    position: relative;
    z-index: 2;
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
    .hero-full-logo {
      height: 56px;
    }
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
    color: var(--hero-strong);
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
    background: var(--hero-search-surface);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    color: var(--hero-strong);
    font-size: 16px;
    font-family: inherit;
    outline: none;
    transition: background 0.2s;
  }

  .hero-search input::placeholder {
    color: var(--hero-muted);
    opacity: 1;
  }

  .hero-search input:focus {
    background: var(--hero-search-focus);
    box-shadow: 0 0 0 3px var(--ring);
  }

  .hero-sub {
    margin: 0 0 6px;
    color: var(--hero-text);
    font-weight: 520;
    font-size: 15px;
  }

  .hero-stat {
    margin: 0;
    color: var(--hero-muted);
    opacity: 0.9;
    font-weight: 520;
    font-size: 13px;
  }

  .hero-view-all {
    display: inline-block;
    margin-top: 20px;
    padding: 11px 22px;
    border: 1px solid var(--primary);
    border-radius: 8px;
    background: var(--primary);
    color: var(--primary-foreground);
    box-shadow: 0 4px 14px color-mix(in srgb, var(--primary) 24%, transparent);
    font-size: 14px;
    font-weight: 650;
    text-decoration: none;
    transition:
      filter 0.15s,
      transform 0.15s,
      box-shadow 0.15s;
  }
  .hero-view-all:hover {
    filter: brightness(1.08);
    transform: translateY(-1px);
    box-shadow: 0 7px 18px color-mix(in srgb, var(--primary) 30%, transparent);
  }
  .hero-view-all:focus-visible {
    outline: 3px solid var(--ring);
    outline-offset: 3px;
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
    .empty-card h2 {
      font-size: 28px;
    }
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
