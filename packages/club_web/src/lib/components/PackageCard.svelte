<script lang="ts">
  import VerifiedBadge from './VerifiedBadge.svelte';
  import ScreenshotGallery from './ScreenshotGallery.svelte';
  import { api } from '$lib/api/client';

  interface CardScreenshot {
    url: string;
    description: string | null;
  }

  interface PackageData {
    name: string;
    description?: string;
    version: string;
    likes?: number;
    points?: number;
    maxPoints?: number;
    downloads?: number;
    tags?: string[];
    topics?: string[];
    publishedAt?: string | null;
    dartSdk?: string | null;
    flutterSdk?: string | null;
    repository?: string | null;
    homepage?: string | null;
    isDiscontinued?: boolean;
    isUnlisted?: boolean;
    publisher?: {
      id: string;
      displayName: string;
      verified: boolean;
    } | null;
    uploader?: { displayName: string; email: string } | null;
    license?: string | null;
    /** Prefetched by the calling loader. When omitted the card lazily
     *  fetches `/list-info` on mount so it still renders a thumbnail. */
    screenshots?: CardScreenshot[];
  }

  interface Props {
    pkg?: PackageData;
    package?: PackageData;
  }

  let { pkg, package: packageData }: Props = $props();
  const data = $derived(pkg ?? packageData);

  // If the caller didn't prefetch screenshots, pull them from `/list-info`
  // so all listing surfaces (my-packages, publisher pages) surface them
  // without each loader having to duplicate the plumbing.
  let lazyScreenshots = $state<CardScreenshot[] | null>(null);
  $effect(() => {
    const n = data?.name;
    if (!n) return;
    if (data?.screenshots !== undefined) return;
    if (lazyScreenshots !== null) return;
    let cancelled = false;
    api
      .get<{ screenshots?: Array<{ url: string; description: string | null }> }>(
        `/api/packages/${encodeURIComponent(n)}/list-info`,
      )
      .then((info) => {
        if (cancelled) return;
        lazyScreenshots = Array.isArray(info?.screenshots)
          ? info.screenshots
              .filter((s) => typeof s?.url === 'string' && s.url.length > 0)
              .map((s) => ({
                url: s.url,
                description:
                  typeof s.description === 'string' && s.description.length > 0
                    ? s.description
                    : null,
              }))
          : [];
      })
      .catch(() => {
        if (!cancelled) lazyScreenshots = [];
      });
    return () => {
      cancelled = true;
    };
  });

  const screenshots = $derived<CardScreenshot[]>(
    data?.screenshots ?? lazyScreenshots ?? [],
  );

  let copied = $state(false);

  function timeAgo(dateStr: string | null | undefined): string {
    if (!dateStr) return '';
    const diff = Date.now() - new Date(dateStr).getTime();
    const days = Math.floor(diff / 86400000);
    if (days === 0) return 'today';
    if (days === 1) return 'yesterday';
    if (days < 30) return `${days} days ago`;
    if (days < 365) return `${Math.floor(days / 30)} months ago`;
    return `${Math.floor(days / 365)} years ago`;
  }

  function formatNumber(n: number): string {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(2)}k`;
    return n.toString();
  }

  async function handleCopy(e: MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    if (!data) return;
    try {
      await navigator.clipboard.writeText(`${data.name}: ^${data.version}`);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Clipboard API may be unavailable on non-secure origins; silently no-op.
    }
  }

  // Platforms come from the scoring tags (`platform:android`, etc.) so the
  // list only shows platforms the package actually supports. Falling back to
  // the "all Flutter platforms" list is misleading for plugins that only
  // build on a subset.
  const PLATFORM_ORDER = [
    'android',
    'ios',
    'linux',
    'macos',
    'web',
    'windows',
  ] as const;

  let platforms = $derived.by(() => {
    const tags = data?.tags ?? [];
    const set = new Set(
      tags
        .filter((t) => t.startsWith('platform:'))
        .map((t) => t.slice('platform:'.length)),
    );
    return PLATFORM_ORDER.filter((p) => set.has(p));
  });

  let sdks = $derived.by(() => {
    const tags = data?.tags ?? [];
    const set = new Set(
      tags.filter((t) => t.startsWith('sdk:')).map((t) => t.slice(4)),
    );
    // Fallback to environment when tags are empty (e.g. unscored package).
    if (set.size === 0) {
      if (data?.flutterSdk) set.add('flutter');
      if (data?.dartSdk) set.add('dart');
    }
    const order = ['dart', 'flutter'] as const;
    return order.filter((s) => set.has(s));
  });
</script>

{#if data}
  <a href="/packages/{data.name}" class="pkg-card">
    <div class="pkg-card-main">
      <div class="pkg-card-header">
        <h3 class="pkg-card-name">{data.name}</h3>
        <button
          class="copy-btn"
          onclick={handleCopy}
          title="Copy dependency"
          aria-label={`Copy ${data.name}: ^${data.version}`}
          type="button"
        >
          {#if copied}
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <polyline points="20 6 9 17 4 12" />
            </svg>
          {:else}
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <rect x="9" y="9" width="13" height="13" rx="2" />
              <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1" />
            </svg>
          {/if}
        </button>
      </div>

      {#if data.description || (data.topics && data.topics.length > 0)}
        <p class="pkg-card-desc">
          {#if data.description}<span>{data.description}</span>{/if}
          {#if data.topics}
            {#each data.topics as topic}
              <span class="pkg-card-topic">#{topic}</span>
            {/each}
          {/if}
        </p>
      {/if}

      <div class="pkg-card-meta">
        <span class="meta-version">v{data.version}</span>
        {#if data.publishedAt}
          <span class="meta-sep" aria-hidden="true">·</span>
          <span class="meta-age">{timeAgo(data.publishedAt)}</span>
        {/if}
        {#if data.publisher}
          <span class="meta-sep" aria-hidden="true">·</span>
          <span class="meta-author">
            {#if data.publisher.verified}
              <VerifiedBadge iconOnly title="Verified publisher" />
              <span class="meta-link">{data.publisher.id}</span>
            {:else}
              <span class="meta-author-text">{data.publisher.displayName}</span>
            {/if}
          </span>
        {:else if data.uploader}
          <span class="meta-sep" aria-hidden="true">·</span>
          <span class="meta-author-text">
            {data.uploader.displayName || data.uploader.email}
          </span>
        {/if}
        {#if data.license}
          <span class="meta-sep" aria-hidden="true">·</span>
          <span class="meta-license">
            <svg
              class="meta-license-icon"
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M12 3v18" />
              <path d="M5 7h14" />
              <path d="M6 7l-3 7c0 1.5 1.3 3 3 3s3-1.5 3-3L6 7z" />
              <path d="M18 7l-3 7c0 1.5 1.3 3 3 3s3-1.5 3-3l-3-7z" />
            </svg>
            <span>{data.license}</span>
          </span>
        {/if}
      </div>

      {#if sdks.length > 0 || platforms.length > 0 || data.isDiscontinued || data.isUnlisted}
        <div class="pkg-card-compat">
          {#if data.isDiscontinued}
            <span class="badge-discontinued">DISCONTINUED</span>
          {/if}
          {#if sdks.length > 0}
            <div class="compat-group">
              <span class="compat-label">SDK</span>
              {#each sdks as s}
                <span class="compat-val">{s.toUpperCase()}</span>
              {/each}
            </div>
          {/if}
          {#if platforms.length > 0}
            <div class="compat-group">
              <span class="compat-label">PLATFORM</span>
              {#each platforms as p}
                <span class="compat-val">{p.toUpperCase()}</span>
              {/each}
            </div>
          {/if}
          {#if data.isUnlisted}
            <span class="badge-unlisted">UNLISTED</span>
          {/if}
        </div>
      {/if}
    </div>

    <div class="pkg-card-aside">
      <div class="pkg-card-stats">
        <div class="stat">
          <span class="stat-val">{formatNumber(data.likes ?? 0)}</span>
          <span class="stat-lbl">likes</span>
        </div>
        <div class="stat">
          <span class="stat-val">{data.points ?? 0}</span>
          <span class="stat-lbl">points</span>
        </div>
        <div class="stat">
          <span class="stat-val">{formatNumber(data.downloads ?? 0)}</span>
          <span class="stat-lbl">downloads</span>
        </div>
      </div>
      {#if screenshots.length > 0}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->
        <!-- The gallery component internally renders <button> for the
             thumbnail and the overlay escapes this wrapper. The outer
             card is an <a>, so we defuse navigation on clicks that land
             inside the gallery — the gallery handles its own click
             semantics (open carousel) from there. -->
        <div
          class="pkg-card-gallery"
          onclick={(e) => {
            e.preventDefault();
            e.stopPropagation();
          }}
        >
          <ScreenshotGallery {screenshots} />
        </div>
      {/if}
    </div>
  </a>
{/if}

<style>
  .pkg-card {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 24px;
    padding: 24px 0;
    border-bottom: 1px solid var(--pub-divider-color);
    text-decoration: none;
    color: inherit;
    transition: background 0.12s;
  }
  .pkg-card:first-child {
    padding-top: 8px;
  }
  .pkg-card:last-child {
    border-bottom: none;
  }
  .pkg-card:hover {
    background: color-mix(in srgb, var(--muted) 40%, transparent);
    margin: 0 -8px;
    padding-left: 8px;
    padding-right: 8px;
    border-radius: 10px;
  }
  @media (min-width: 640px) {
    .pkg-card:hover {
      margin: 0 -16px;
      padding-left: 16px;
      padding-right: 16px;
    }
  }

  .pkg-card-main {
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .pkg-card-header {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }
  .pkg-card-name {
    margin: 0;
    font-size: 18px;
    font-weight: 600;
    color: var(--pub-link-text-color);
    line-height: 1.25;
    letter-spacing: -0.005em;
    overflow-wrap: anywhere;
  }

  .copy-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 1px solid transparent;
    border-radius: 6px;
    padding: 4px;
    color: var(--pub-muted-text-color);
    cursor: pointer;
    opacity: 0.6;
    transition:
      opacity 0.12s,
      color 0.12s,
      background 0.12s,
      border-color 0.12s;
  }
  .copy-btn:hover {
    opacity: 1;
    color: var(--pub-link-text-color);
    background: color-mix(in srgb, var(--pub-link-text-color) 8%, transparent);
    border-color: color-mix(in srgb, var(--pub-link-text-color) 20%, transparent);
  }
  .copy-btn:focus-visible {
    outline: 2px solid var(--pub-link-text-color);
    outline-offset: 2px;
  }

  .pkg-card-desc {
    margin: 0;
    font-size: 14px;
    line-height: 1.55;
    color: var(--pub-default-text-color);
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .pkg-card-topic {
    color: var(--pub-link-text-color);
    font-weight: 500;
    white-space: nowrap;
    margin-left: 6px;
  }

  .pkg-card-meta {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .meta-version {
    font-family: var(--pub-code-font-family);
    color: var(--pub-default-text-color);
  }
  .meta-sep {
    opacity: 0.5;
  }
  .meta-link {
    color: var(--pub-link-text-color);
  }
  .meta-author {
    display: inline-flex;
    align-items: center;
    gap: 4px;
  }
  .meta-author :global(.badge) {
    font-size: 13px;
  }
  .meta-author-text {
    color: var(--pub-default-text-color);
  }
  .meta-license {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: var(--pub-muted-text-color);
  }
  .meta-license-icon {
    flex-shrink: 0;
    opacity: 0.8;
  }

  .pkg-card-compat {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
  }
  .compat-group {
    display: flex;
    align-items: center;
  }
  .compat-label {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 6px 8px;
    background: color-mix(in srgb, var(--pub-link-text-color) 20%, transparent);
    color: var(--pub-link-text-color);
    border-radius: 4px 0 0 4px;
  }
  .compat-val {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.04em;
    padding: 6px 8px;
    background: var(--pub-tag-background);
    color: var(--pub-tag-text-color);
    border-right: 1px solid
      color-mix(in srgb, var(--pub-tag-text-color) 12%, transparent);
  }
  .compat-val:last-child {
    border-right: none;
    border-radius: 0 4px 4px 0;
  }

  .badge-discontinued {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 3px 10px;
    background: var(--pub-error-color);
    color: #fff;
    border-radius: 4px;
  }
  .badge-unlisted {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.05em;
    padding: 3px 10px;
    background: var(--pub-tag-background);
    color: var(--pub-tag-text-color);
    border: 1px solid var(--border);
    border-radius: 4px;
  }

  .pkg-card-aside {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 14px;
    flex-shrink: 0;
    min-width: 0;
  }

  /* Constrain the gallery to a compact card-corner tile (pub.dev-style).
     The ScreenshotGallery component's `.thumb` uses width:100% + a 1:1
     aspect ratio, so bounding the wrapper width is enough to size it. */
  .pkg-card-gallery {
    width: 110px;
  }

  .pkg-card-stats {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, auto));
    column-gap: 4px;
    align-items: start;
    padding-top: 4px;
    flex-shrink: 0;
  }
  .stat {
    display: flex;
    flex-direction: column;
    align-items: center;
    min-width: 64px;
    padding: 0 10px;
    border-right: 1px solid var(--pub-divider-color);
  }
  .stat:last-child {
    border-right: none;
  }
  .stat-val {
    font-size: 22px;
    font-weight: 400;
    color: var(--pub-link-text-color);
    line-height: 1.1;
    letter-spacing: -0.01em;
  }
  .stat-lbl {
    margin-top: 3px;
    font-size: 10px;
    font-weight: 600;
    color: var(--pub-muted-text-color);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }

  @media (max-width: 640px) {
    .pkg-card {
      grid-template-columns: minmax(0, 1fr);
      gap: 12px;
      padding: 18px 0;
    }
    .pkg-card-name {
      font-size: 16px;
    }
    .pkg-card-aside {
      align-items: flex-start;
      flex-direction: row;
      align-items: center;
      gap: 16px;
    }
    .pkg-card-stats {
      justify-content: flex-start;
      padding-top: 0;
    }
    .pkg-card-gallery {
      width: 72px;
    }
    .stat {
      min-width: 0;
      padding: 0 14px 0 0;
      align-items: flex-start;
    }
    .stat:first-child {
      padding-left: 0;
    }
    .stat-val {
      font-size: 18px;
    }
  }
</style>
