<script lang="ts">
  import { api, ApiError } from '$lib/api/client';
  import { confirmDialog } from '$lib/stores/confirm';
  import { lockScroll } from '$lib/utils/scrollLock';

  interface MissingVersion {
    package: string;
    version: string;
    publishedAt: string;
  }

  interface Props {
    open: boolean;
    items: MissingVersion[];
    onChange: (items: MissingVersion[]) => void;
    onClose: () => void;
  }

  let { open, items, onChange, onClose }: Props = $props();

  let busyKey = $state<string | null>(null);
  let error = $state('');

  function close() {
    if (busyKey !== null) return;
    onClose();
  }

  function handleBackdropClick(e: MouseEvent) {
    if (e.target === e.currentTarget) close();
  }

  $effect(() => {
    if (!open) return;
    function onKeydown(e: KeyboardEvent) {
      if (e.key === 'Escape' && busyKey === null) {
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

  function keyOf(m: MissingVersion) {
    return `${m.package}@${m.version}`;
  }

  async function deleteVersion(m: MissingVersion) {
    const ok = await confirmDialog({
      title: `Delete ${m.package} ${m.version}?`,
      description: `The tarball is already missing; this just removes the stranded database record.`,
      confirmLabel: 'Delete',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    busyKey = keyOf(m);
    error = '';
    try {
      await api.delete(`/api/admin/packages/${encodeURIComponent(m.package)}/versions/${encodeURIComponent(m.version)}`);
      onChange(items.filter((x) => keyOf(x) !== keyOf(m)));
    } catch (e) {
      error = e instanceof ApiError ? (e.body as any)?.error?.message ?? e.message : 'Failed to delete version.';
    } finally {
      busyKey = null;
    }
  }

  async function deletePackage(pkg: string) {
    const ok = await confirmDialog({
      title: `Delete package ${pkg}?`,
      description: `This removes the database entry and every version under it. Any remaining tarballs on disk will also be removed.`,
      confirmLabel: 'Delete',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    busyKey = `pkg:${pkg}`;
    error = '';
    try {
      await api.delete(`/api/admin/packages/${encodeURIComponent(pkg)}`);
      onChange(items.filter((x) => x.package !== pkg));
    } catch (e) {
      error = e instanceof ApiError ? (e.body as any)?.error?.message ?? e.message : 'Failed to delete package.';
    } finally {
      busyKey = null;
    }
  }
</script>

{#if open && items.length > 0}
  <div
    class="backdrop"
    role="presentation"
    onclick={handleBackdropClick}
  >
    <div
      class="panel"
      role="dialog"
      aria-modal="true"
      aria-labelledby="integrity-title"
      aria-describedby="integrity-desc"
    >
      <div class="head">
        <div class="head-text">
          <strong id="integrity-title">Missing package tarballs</strong>
          <p id="integrity-desc">
            {items.length} package version{items.length === 1 ? '' : 's'} exist in the database but their tarball files are missing on disk.
            Restore the files, or remove the stranded entries.
          </p>
        </div>
        <button
          class="dismiss"
          onclick={close}
          disabled={busyKey !== null}
          aria-label="Dismiss"
        >&times;</button>
      </div>

      {#if error}
        <div class="error">{error}</div>
      {/if}

      <ul class="list">
        {#each items as m (keyOf(m))}
          <li>
            <span class="id">
              <span class="pkg">{m.package}</span>
              <span class="ver">{m.version}</span>
            </span>
            <span class="actions">
              <button
                class="btn"
                disabled={busyKey !== null}
                onclick={() => deleteVersion(m)}
              >
                {busyKey === keyOf(m) ? 'Deleting…' : 'Delete version'}
              </button>
              <button
                class="btn danger"
                disabled={busyKey !== null}
                onclick={() => deletePackage(m.package)}
              >
                {busyKey === `pkg:${m.package}` ? 'Deleting…' : 'Delete package'}
              </button>
            </span>
          </li>
        {/each}
      </ul>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: color-mix(in srgb, var(--foreground) 40%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    z-index: 200;
    -webkit-backdrop-filter: blur(2px);
    backdrop-filter: blur(2px);
  }

  .panel {
    width: 100%;
    max-width: 36rem;
    max-height: calc(100vh - 2rem);
    display: flex;
    flex-direction: column;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    box-shadow: 0 10px 40px color-mix(in srgb, var(--foreground) 30%, transparent);
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
    color: var(--destructive);
    font-size: 14px;
    margin-bottom: 4px;
  }
  .head p {
    margin: 0;
    color: var(--muted-foreground);
    line-height: 1.5;
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
  .dismiss:hover:not(:disabled) {
    background: var(--accent);
    color: var(--foreground);
  }
  .dismiss:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .error {
    margin: 0 20px 12px;
    padding: 8px 12px;
    background: color-mix(in srgb, var(--destructive) 12%, transparent);
    border-radius: 6px;
    color: var(--destructive);
    font-size: 12px;
  }
  .list {
    flex: 1 1 auto;
    margin: 0;
    padding: 0 20px 18px;
    list-style: none;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
  .list li {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 10px 0;
    border-top: 1px solid var(--border);
  }
  .list li:first-child {
    border-top: none;
  }
  .id {
    display: inline-flex;
    align-items: baseline;
    gap: 8px;
    min-width: 0;
  }
  .pkg {
    font-weight: 600;
    color: var(--foreground);
    word-break: break-all;
  }
  .ver {
    font-family: var(--pub-code-font-family);
    color: var(--muted-foreground);
    font-size: 12px;
  }
  .actions {
    display: inline-flex;
    gap: 6px;
    flex-shrink: 0;
  }
  .btn {
    padding: 4px 10px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--card);
    color: var(--foreground);
    font-size: 12px;
    font-weight: 500;
    cursor: pointer;
    font-family: inherit;
    transition: background 0.12s, border-color 0.12s;
  }
  .btn:hover:not(:disabled) { background: var(--accent); }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn.danger {
    color: var(--destructive);
    border-color: color-mix(in srgb, var(--destructive) 40%, var(--border));
  }
  .btn.danger:hover:not(:disabled) {
    background: var(--destructive);
    color: #fff;
    border-color: var(--destructive);
  }
</style>
