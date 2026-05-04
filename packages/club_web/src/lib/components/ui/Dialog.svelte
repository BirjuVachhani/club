<script lang="ts">
  /**
   * Minimal confirmation dialog. Not a general-purpose modal system —
   * intentionally focused on the "confirm this destructive thing" use
   * case (ownership transfer, delete publisher, delete package).
   *
   * Supports an optional typed-confirmation gate: set `confirmText` and
   * the primary button stays disabled until the user types that exact
   * string. Use for anything you can't undo.
   *
   * Usage:
   *   <Dialog
   *     bind:open
   *     title="Transfer ownership"
   *     description="..."
   *     confirmLabel="Transfer"
   *     confirmText="transfer ownership"
   *     onConfirm={handleConfirm}
   *   >
   *     {#snippet body()}  ...custom content...  {/snippet}
   *   </Dialog>
   */
  import type { Snippet } from 'svelte';
  import Button from './Button.svelte';
  import { lockScroll } from '$lib/utils/scrollLock';

  interface Props {
    open: boolean;
    title: string;
    description?: string;
    confirmLabel?: string;
    cancelLabel?: string;
    confirmVariant?: 'default' | 'destructive';
    /** If set, user must type this exact string before Confirm enables. */
    confirmText?: string;
    /** If set, Confirm is disabled and Cancel is the only way out. */
    busy?: boolean;
    /**
     * Render above any other open dialogs. Use for programmatic
     * confirmations that may layer over an existing modal.
     */
    topLayer?: boolean;
    onConfirm: () => void | Promise<void>;
    onCancel?: () => void;
    body?: Snippet;
    /**
     * Custom prompt text rendered above the typed-confirmation input.
     * If omitted, falls back to a generic "Type "X" to confirm deletion.".
     */
    typedPrompt?: Snippet;
  }

  let {
    open = $bindable(),
    title,
    description,
    confirmLabel = 'Confirm',
    cancelLabel = 'Cancel',
    confirmVariant = 'default',
    confirmText,
    busy = false,
    topLayer = false,
    onConfirm,
    onCancel,
    body,
    typedPrompt
  }: Props = $props();

  let typed = $state('');

  const needsTyped = $derived(!!confirmText && confirmText.length > 0);
  const confirmDisabled = $derived(
    busy || (needsTyped && typed !== confirmText)
  );

  function close() {
    open = false;
    typed = '';
    onCancel?.();
  }

  async function handleConfirm() {
    await onConfirm();
    // Caller decides whether to close by flipping `open` — if they
    // want the dialog to stay open after an error, they keep it open.
    typed = '';
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget && !busy) close();
  }

  $effect(() => {
    if (!open) return;
    function onKeydown(e: KeyboardEvent) {
      if (e.key === 'Escape' && !busy) {
        e.stopImmediatePropagation();
        close();
      }
    }
    window.addEventListener('keydown', onKeydown, true);
    const unlock = lockScroll();
    return () => {
      window.removeEventListener('keydown', onKeydown, true);
      unlock();
    };
  });
</script>

{#if open}
  <div
    class="backdrop"
    class:top-layer={topLayer}
    role="presentation"
    onclick={handleBackdropClick}
  >
    <div
      class="panel"
      role="dialog"
      aria-modal="true"
      aria-labelledby="dialog-title"
    >
      <h2 id="dialog-title" class="title">{title}</h2>
      {#if description}
        <p class="description">{description}</p>
      {/if}

      {#if body}
        <div class="body">{@render body()}</div>
      {/if}

      {#if needsTyped}
        <label class="typed-label">
          {#if typedPrompt}
            {@render typedPrompt()}
          {:else}
            Type <code>"{confirmText}"</code> to confirm deletion.
          {/if}
          <input
            type="text"
            bind:value={typed}
            disabled={busy}
            autocomplete="off"
            autocorrect="off"
            spellcheck="false"
            class="typed-input"
          />
        </label>
      {/if}

      <div class="actions">
        <Button variant="outline" onclick={close} disabled={busy}>
          {cancelLabel}
        </Button>
        <Button
          variant={confirmVariant}
          onclick={handleConfirm}
          disabled={confirmDisabled}
        >
          {busy ? 'Working...' : confirmLabel}
        </Button>
      </div>
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

  .backdrop.top-layer {
    z-index: calc(var(--dialog-z) + 100);
  }

  .panel {
    width: 100%;
    max-width: 28rem;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: var(--dialog-radius);
    padding: 1.5rem;
    box-shadow: var(--dialog-shadow);
  }

  .title {
    font-size: 1.125rem;
    font-weight: 600;
    margin: 0 0 0.5rem;
    color: var(--foreground);
  }

  .description {
    font-size: 0.875rem;
    color: var(--muted-foreground);
    margin: 0 0 1rem;
    line-height: 1.5;
  }

  .body {
    margin: 0.75rem 0 1rem;
    font-size: 0.875rem;
  }

  .typed-label {
    display: block;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
    margin-bottom: 1rem;
  }

  .typed-label code {
    background: var(--muted);
    border: 1px solid var(--border);
    padding: 0.1rem 0.35rem;
    border-radius: 4px;
    font-size: 0.8em;
    color: var(--foreground);
    font-family: var(--font-mono);
  }

  .typed-input {
    width: 100%;
    margin-top: 0.5rem;
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--foreground);
    font-size: 0.875rem;
    font-family: var(--font-mono);
  }

  .typed-input:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 40%, transparent);
  }

  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    margin-top: 1rem;
  }
</style>
