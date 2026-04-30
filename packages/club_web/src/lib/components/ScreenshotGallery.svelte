<script lang="ts">
  /**
   * Screenshot gallery. Renders a single sidebar thumbnail that opens into
   * a fullscreen carousel on click. The carousel is keyboard-navigable
   * (←/→/Esc), swipeable on touch, and traps focus while open.
   *
   * The only asset it expects per entry is a `url` (absolute, same-origin
   * under `/api/packages/...`). `description` is optional and rendered as
   * a caption in the bottom-left of the carousel overlay.
   */
  import { ChevronLeft, ChevronRight, Images, X } from 'lucide-svelte';
  import { lockScroll } from '$lib/utils/scrollLock';

  interface Screenshot {
    url: string;
    description: string | null;
  }

  interface Props {
    screenshots: Screenshot[];
  }

  let { screenshots }: Props = $props();

  let open = $state(false);
  let active = $state(0);
  let overlay: HTMLDivElement | null = $state(null);
  let touchStartX = 0;
  let touchStartY = 0;

  const count = $derived(screenshots.length);
  const current = $derived(screenshots[active]);

  function openAt(i: number) {
    active = i;
    open = true;
  }

  function close() {
    open = false;
  }

  function next() {
    if (count < 2) return;
    active = (active + 1) % count;
  }

  function prev() {
    if (count < 2) return;
    active = (active - 1 + count) % count;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (!open) return;
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      next();
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      prev();
    }
  }

  function onBackdropClick(e: MouseEvent) {
    // Close on any click outside the image itself and the interactive
    // chrome (nav arrows, close button, thumbnail strip). Using a
    // `closest` check rather than `target === currentTarget` lets us
    // treat the `.stage` wrapper, `.chrome` row, and any empty space as
    // dismissal zones — the naive equality check misses all of those
    // because the click lands on those wrapper divs, not on the overlay.
    const target = e.target as HTMLElement | null;
    if (!target?.closest('.viewer, .nav, .close, .strip-item')) {
      close();
    }
  }

  function onTouchStart(e: TouchEvent) {
    const t = e.changedTouches[0];
    touchStartX = t.clientX;
    touchStartY = t.clientY;
  }

  function onTouchEnd(e: TouchEvent) {
    const t = e.changedTouches[0];
    const dx = t.clientX - touchStartX;
    const dy = t.clientY - touchStartY;
    // Horizontal intent threshold — avoids hijacking vertical scroll on
    // thumbnail strip taps. 40px is wide enough to ignore accidental
    // drags from a tap with slight drift.
    if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) {
      if (dx < 0) next();
      else prev();
    }
  }

  // Body-scroll lock while the overlay is up so the page behind can't
  // scroll under the backdrop. lockScroll handles both <html> and <body>
  // and restores prior values so nested modals don't clobber each other.
  $effect(() => {
    if (!open) return;
    const unlock = lockScroll();
    overlay?.focus();
    return unlock;
  });

  // Preload neighbours so nav feels instant — only once the carousel is
  // open (avoids bandwidth cost when the page just has the sidebar tile).
  let preloaded = $state<Set<number>>(new Set());
  $effect(() => {
    if (!open || count < 2) return;
    const targets = [
      active,
      (active + 1) % count,
      (active - 1 + count) % count,
    ];
    for (const i of targets) {
      if (preloaded.has(i)) continue;
      const img = new Image();
      img.src = screenshots[i].url;
      preloaded.add(i);
    }
  });
</script>

<svelte:window onkeydown={handleKeydown} />

{#if count > 0}
  <button
    type="button"
    class="thumb"
    aria-label={count > 1
      ? `Open screenshot gallery (${count} images)`
      : 'Open screenshot'}
    onclick={() => openAt(0)}
  >
    <img
      src={screenshots[0].url}
      alt={screenshots[0].description ?? 'Screenshot preview'}
      loading="lazy"
      decoding="async"
    />
    {#if count > 1}
      <span class="badge" aria-hidden="true">
        <Images size={14} strokeWidth={2} />
        <span class="badge-count">{count}</span>
      </span>
    {/if}
  </button>
{/if}

{#if open && current}
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions a11y_click_events_have_key_events -->
  <div
    class="overlay"
    role="dialog"
    aria-modal="true"
    aria-label="Screenshot gallery"
    tabindex="-1"
    bind:this={overlay}
    onclick={onBackdropClick}
    onkeydown={handleKeydown}
    ontouchstart={onTouchStart}
    ontouchend={onTouchEnd}
  >
    <div class="stage">
      <img
        class="viewer"
        src={current.url}
        alt={current.description ?? `Screenshot ${active + 1} of ${count}`}
        draggable="false"
      />
    </div>

    {#if count > 1}
      <button
        type="button"
        class="nav prev"
        aria-label="Previous screenshot"
        onclick={(e) => {
          e.stopPropagation();
          prev();
        }}
      >
        <ChevronLeft size={28} strokeWidth={1.75} />
      </button>
      <button
        type="button"
        class="nav next"
        aria-label="Next screenshot"
        onclick={(e) => {
          e.stopPropagation();
          next();
        }}
      >
        <ChevronRight size={28} strokeWidth={1.75} />
      </button>
    {/if}

    <button
      type="button"
      class="close"
      aria-label="Close gallery"
      onclick={(e) => {
        e.stopPropagation();
        close();
      }}
    >
      <X size={20} strokeWidth={1.75} />
    </button>

    <div class="chrome">
      <div class="caption-slot">
        {#if current.description}
          <p class="caption">{current.description}</p>
        {/if}
      </div>
      <div class="counter" aria-live="polite">
        <span class="counter-cur">{active + 1}</span>
        <span class="counter-sep">/</span>
        <span class="counter-tot">{count}</span>
      </div>
    </div>

    {#if count > 1}
      <div class="strip" role="tablist" aria-label="Gallery thumbnails">
        {#each screenshots as s, i (s.url)}
          <button
            type="button"
            role="tab"
            aria-selected={i === active}
            class="strip-item"
            class:active={i === active}
            onclick={(e) => {
              e.stopPropagation();
              active = i;
            }}
          >
            <img
              src={s.url}
              alt=""
              loading="lazy"
              decoding="async"
              draggable="false"
            />
          </button>
        {/each}
      </div>
    {/if}
  </div>
{/if}

<style>
  /* ── Sidebar thumbnail ──────────────────────────────────────── */

  .thumb {
    position: relative;
    display: block;
    width: 100%;
    aspect-ratio: 1 / 1;
    padding: 0;
    background: var(--pub-code-background);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    cursor: pointer;
    transition: border-color 160ms ease, transform 160ms ease;
  }

  .thumb:hover {
    border-color: color-mix(in oklab, var(--primary) 40%, var(--border));
  }

  .thumb:focus-visible {
    outline: 2px solid var(--ring);
    outline-offset: 2px;
  }

  .thumb img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: contain;
    background: var(--pub-code-background);
  }

  .badge {
    position: absolute;
    bottom: 8px;
    right: 8px;
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 7px;
    border-radius: 6px;
    background: rgba(12, 13, 16, 0.78);
    color: #f5f5f6;
    font-size: 11px;
    font-weight: 600;
    line-height: 1;
    letter-spacing: 0.02em;
    pointer-events: none;
    -webkit-backdrop-filter: saturate(1.1);
    backdrop-filter: saturate(1.1);
  }

  .badge-count {
    font-variant-numeric: tabular-nums;
  }

  /* ── Fullscreen overlay ─────────────────────────────────────── */

  .overlay {
    position: fixed;
    inset: 0;
    z-index: 300;
    /* Solid near-black — intentionally flat, no blur, no gradient. */
    background: rgb(11 12 14 / 0.985);
    display: grid;
    grid-template-rows: 1fr auto auto;
    animation: gallery-fade 140ms ease-out;
  }

  .overlay:focus {
    outline: none;
  }

  @keyframes gallery-fade {
    from {
      opacity: 0;
    }
  }

  .stage {
    grid-row: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: clamp(16px, 3vw, 48px);
    min-height: 0;
    overflow: hidden;
  }

  .viewer {
    max-width: 100%;
    max-height: 100%;
    object-fit: contain;
    -webkit-user-select: none;
    user-select: none;
    -webkit-user-drag: none;
    animation: gallery-pop 220ms cubic-bezier(0.2, 0.8, 0.2, 1);
    box-shadow:
      0 24px 48px -24px rgba(0, 0, 0, 0.6),
      0 2px 8px rgba(0, 0, 0, 0.3);
  }

  @keyframes gallery-pop {
    from {
      opacity: 0;
      transform: scale(0.985);
    }
  }

  /* ── Chrome: caption + counter ─────────────────────────────── */

  .chrome {
    grid-row: 2;
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 24px;
    padding: 0 clamp(20px, 4vw, 48px) 16px;
    pointer-events: none;
  }

  .caption-slot {
    flex: 1;
    min-width: 0;
    max-width: 60ch;
  }

  .caption {
    margin: 0;
    color: rgba(245, 245, 246, 0.92);
    font-size: 14px;
    line-height: 1.5;
    letter-spacing: 0;
    /* Subtle legibility band — text-shadow rather than a glass panel so the
       caption sits quietly against the image. */
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.8);
    display: -webkit-box;
    line-clamp: 3;
    -webkit-line-clamp: 3;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .counter {
    flex: 0 0 auto;
    display: inline-flex;
    align-items: baseline;
    gap: 4px;
    font-family: var(--font-mono);
    font-size: 12px;
    color: rgba(245, 245, 246, 0.6);
    letter-spacing: 0.02em;
    font-variant-numeric: tabular-nums;
  }

  .counter-cur {
    color: rgba(245, 245, 246, 0.92);
  }

  /* ── Thumb strip ───────────────────────────────────────────── */

  .strip {
    grid-row: 3;
    display: flex;
    gap: 8px;
    justify-content: center;
    align-items: center;
    padding: 0 clamp(16px, 3vw, 32px) clamp(16px, 3vw, 28px);
    overflow-x: auto;
    scrollbar-width: none;
  }
  .strip::-webkit-scrollbar {
    display: none;
  }

  .strip-item {
    flex: 0 0 auto;
    width: 64px;
    height: 64px;
    padding: 0;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 8px;
    overflow: hidden;
    cursor: pointer;
    transition: border-color 140ms ease, opacity 140ms ease,
      transform 140ms ease;
    opacity: 0.55;
  }

  .strip-item:hover {
    opacity: 0.9;
    border-color: rgba(255, 255, 255, 0.2);
  }

  .strip-item.active {
    opacity: 1;
    border-color: var(--primary);
    transform: translateY(-1px);
  }

  .strip-item img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  /* ── Nav buttons ───────────────────────────────────────────── */

  .nav {
    position: absolute;
    top: 50%;
    transform: translateY(-50%);
    width: 48px;
    height: 48px;
    display: grid;
    place-items: center;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 999px;
    color: rgba(245, 245, 246, 0.92);
    cursor: pointer;
    transition: background 140ms ease, transform 140ms ease;
  }

  .nav:hover {
    background: rgba(255, 255, 255, 0.12);
    transform: translateY(-50%) scale(1.04);
  }

  .nav:focus-visible {
    outline: 2px solid var(--primary);
    outline-offset: 2px;
  }

  .nav.prev {
    left: clamp(12px, 2vw, 24px);
  }

  .nav.next {
    right: clamp(12px, 2vw, 24px);
  }

  /* ── Close button ──────────────────────────────────────────── */

  .close {
    position: absolute;
    top: clamp(12px, 2vw, 20px);
    right: clamp(12px, 2vw, 20px);
    width: 36px;
    height: 36px;
    display: grid;
    place-items: center;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 999px;
    color: rgba(245, 245, 246, 0.9);
    cursor: pointer;
    transition: background 140ms ease;
  }

  .close:hover {
    background: rgba(255, 255, 255, 0.14);
  }

  .close:focus-visible {
    outline: 2px solid var(--primary);
    outline-offset: 2px;
  }

  /* Hide edge nav on very small viewports — the swipe gesture + thumb
     strip provide adequate alternatives and the chevrons would obscure
     the image on phones. */
  @media (max-width: 480px) {
    .nav {
      display: none;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .overlay,
    .viewer {
      animation: none;
    }
    .nav:hover {
      transform: translateY(-50%);
    }
  }
</style>
