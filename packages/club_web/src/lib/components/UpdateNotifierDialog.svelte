<script lang="ts">
  import { lockScroll } from '$lib/utils/scrollLock';
  import { renderMarkdown } from '$lib/utils/markdown';

  interface Props {
    open: boolean;
    running: string;
    latest: string;
    releaseUrl: string | null;
    releaseNotes: string | null;
    onOk: () => void;
    onRemindLater: () => void;
  }

  let {
    open,
    running,
    latest,
    releaseUrl,
    releaseNotes,
    onOk,
    onRemindLater
  }: Props = $props();

  // Either button is a "soft close" — the parent decides which one to
  // wire to which dismissal store. Treat clicking the backdrop or
  // pressing Escape the same as Remind-me-later: the admin closed the
  // dialog without committing, so we should re-prompt rather than
  // permanently dismiss.
  function softClose() {
    onRemindLater();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) softClose();
  }

  $effect(() => {
    if (!open) return;
    function onKeydown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        e.stopImmediatePropagation();
        softClose();
      }
    }
    window.addEventListener('keydown', onKeydown, true);
    const unlock = lockScroll();
    return () => {
      window.removeEventListener('keydown', onKeydown, true);
      unlock();
    };
  });

  let renderedNotes = $derived(
    releaseNotes && releaseNotes.trim().length > 0
      ? renderMarkdown(releaseNotes)
      : ''
  );
</script>

{#if open}
  <div
    class="backdrop"
    role="presentation"
    onclick={handleBackdropClick}
  >
    <div
      class="panel"
      role="dialog"
      aria-modal="true"
      aria-labelledby="update-title"
    >
      <header class="head">
        <div class="head-text">
          <strong id="update-title">Club update available</strong>
          <p class="versions">
            <span class="ver-from">{running}</span>
            <span class="arrow" aria-hidden="true">→</span>
            <span class="ver-to">{latest}</span>
          </p>
        </div>
        <button
          class="dismiss"
          onclick={softClose}
          aria-label="Close — remind me later"
        >&times;</button>
      </header>

      <div class="body">
        {#if renderedNotes}
          <!-- eslint-disable-next-line svelte/no-at-html-tags -->
          <div class="notes">{@html renderedNotes}</div>
        {:else}
          <p class="empty">No release notes were published for this release.</p>
        {/if}
      </div>

      <footer class="actions">
        {#if releaseUrl}
          <a
            class="btn ghost"
            href={releaseUrl}
            target="_blank"
            rel="noopener noreferrer"
          >View on GitHub</a>
        {/if}
        <span class="spacer"></span>
        <button class="btn" onclick={onRemindLater}>Remind me later</button>
        <button class="btn primary" onclick={onOk}>OK</button>
      </footer>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: var(--dialog-overlay);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    z-index: var(--dialog-z);
    -webkit-backdrop-filter: var(--dialog-overlay-blur);
    backdrop-filter: var(--dialog-overlay-blur);
  }

  .panel {
    width: 100%;
    max-width: 36rem;
    max-height: calc(100vh - 2rem);
    display: flex;
    flex-direction: column;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: var(--dialog-radius);
    box-shadow: var(--dialog-shadow);
    color: var(--foreground);
    font-size: 13px;
    overflow: hidden;
  }

  .head {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    gap: 16px;
    padding: 18px 20px 14px;
  }
  .head-text {
    min-width: 0;
  }
  .head strong {
    display: block;
    font-size: 14px;
    color: var(--foreground);
    margin-bottom: 4px;
  }
  .versions {
    margin: 0;
    color: var(--muted-foreground);
    font-family: var(--pub-code-font-family);
    font-size: 12px;
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .ver-from {
    color: var(--muted-foreground);
  }
  .arrow {
    color: var(--muted-foreground);
  }
  .ver-to {
    color: var(--foreground);
    font-weight: 600;
  }
  .dismiss {
    background: transparent;
    border: none;
    color: var(--muted-foreground);
    cursor: pointer;
    font-size: 20px;
    line-height: 1;
    padding: 4px 8px;
    border-radius: 6px;
    flex-shrink: 0;
  }
  .dismiss:hover {
    background: var(--accent);
    color: var(--foreground);
  }

  .body {
    flex: 1 1 auto;
    overflow-y: auto;
    overscroll-behavior: contain;
    padding: 0 20px 16px;
    border-top: 1px solid var(--border);
    padding-top: 14px;
  }
  .notes {
    color: var(--foreground);
    line-height: 1.55;
  }
  .notes :global(h1),
  .notes :global(h2),
  .notes :global(h3),
  .notes :global(h4) {
    font-size: 13px;
    font-weight: 600;
    margin: 12px 0 4px;
    color: var(--foreground);
  }
  .notes :global(h1:first-child),
  .notes :global(h2:first-child),
  .notes :global(h3:first-child),
  .notes :global(h4:first-child) {
    margin-top: 0;
  }
  .notes :global(p) {
    margin: 0 0 8px;
  }
  /* Tailwind preflight zeroes out list-style on ul/ol; restore the
     default disc/decimal markers inside the dialog so release notes
     render with visible bullets. */
  .notes :global(ul) {
    margin: 0 0 8px;
    padding-left: 18px;
    list-style: disc outside;
  }
  .notes :global(ol) {
    margin: 0 0 8px;
    padding-left: 18px;
    list-style: decimal outside;
  }
  .notes :global(li) {
    margin-bottom: 3px;
  }
  .notes :global(code) {
    font-family: var(--pub-code-font-family);
    font-size: 12px;
    background: var(--secondary);
    padding: 1px 5px;
    border-radius: 4px;
  }
  .notes :global(a) {
    color: var(--primary, #2563eb);
    text-decoration: underline;
  }
  .notes :global(strong) {
    font-weight: 600;
  }
  .empty {
    margin: 0;
    color: var(--muted-foreground);
    font-style: italic;
  }

  .actions {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 14px 20px 16px;
    border-top: 1px solid var(--border);
  }
  .spacer {
    flex: 1 1 auto;
  }
  .btn {
    padding: 6px 14px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--card);
    color: var(--foreground);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
    font-family: inherit;
    text-decoration: none;
    line-height: 1.4;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
  }
  .btn:hover {
    background: var(--accent);
  }
  .btn.primary {
    background: var(--foreground);
    color: var(--background);
    border-color: var(--foreground);
  }
  .btn.primary:hover {
    background: color-mix(in srgb, var(--foreground) 88%, transparent);
  }
  .btn.ghost {
    background: transparent;
    color: var(--muted-foreground);
  }
  .btn.ghost:hover {
    background: var(--accent);
    color: var(--foreground);
  }
</style>
