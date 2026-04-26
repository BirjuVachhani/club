<script lang="ts">
  import { onMount } from 'svelte';
  import { api, apiErrorMessage } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';
  import { isOwner } from '$lib/utils/permissions';
  import Button from '$lib/components/ui/Button.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';
  import InlineMessage from '$lib/components/ui/InlineMessage.svelte';
  import MarkdownRenderer from '$lib/components/MarkdownRenderer.svelte';

  type DocKind = 'privacy' | 'terms';
  type ViewMode = 'edit' | 'preview';

  interface LegalResponse {
    markdown: string;
    isCustom: boolean;
  }

  interface DocState {
    // The markdown currently shown to visitors on /privacy or /terms.
    // When `isCustom` is false, this equals the default bundled with
    // the server (so the textarea can present it for easy editing).
    serverMarkdown: string;
    isCustom: boolean;
    // Working copy in the textarea. Diverges from `serverMarkdown`
    // whenever the user has made unsaved edits.
    draft: string;
    loading: boolean;
    saving: boolean;
    resetting: boolean;
    error: string;
    success: string;
  }

  function emptyDoc(): DocState {
    return {
      serverMarkdown: '',
      isCustom: false,
      draft: '',
      loading: true,
      saving: false,
      resetting: false,
      error: '',
      success: '',
    };
  }

  const user = $derived($auth.user);
  const canEdit = $derived(isOwner(user));

  let active = $state<DocKind>('privacy');
  let mode = $state<ViewMode>('edit');

  const docs: Record<DocKind, DocState> = $state({
    privacy: emptyDoc(),
    terms: emptyDoc(),
  });

  const current = $derived(docs[active]);
  const dirty = $derived(current.draft !== current.serverMarkdown);

  let resetDialogOpen = $state(false);

  onMount(() => {
    void loadDoc('privacy');
    void loadDoc('terms');
  });

  async function loadDoc(kind: DocKind) {
    docs[kind].loading = true;
    docs[kind].error = '';
    try {
      const res = await api.get<LegalResponse>(`/api/legal/${kind}`);
      docs[kind].serverMarkdown = res.markdown;
      docs[kind].isCustom = res.isCustom;
      docs[kind].draft = res.markdown;
    } catch (err) {
      docs[kind].error = apiErrorMessage(err, 'Failed to load content.');
    } finally {
      docs[kind].loading = false;
    }
  }

  async function save() {
    if (!canEdit || current.saving) return;
    docs[active].saving = true;
    docs[active].error = '';
    docs[active].success = '';
    try {
      const res = await api.put<LegalResponse>(
        `/api/admin/legal/${active}`,
        { markdown: current.draft },
      );
      docs[active].serverMarkdown = res.markdown;
      docs[active].isCustom = res.isCustom;
      docs[active].draft = res.markdown;
      docs[active].success = res.isCustom
        ? 'Saved. Visitors now see your custom content.'
        : 'Saved. Empty content — reverted to the default.';
    } catch (err) {
      docs[active].error = apiErrorMessage(err, 'Failed to save content.');
    } finally {
      docs[active].saving = false;
    }
  }

  async function confirmReset() {
    if (!canEdit || current.resetting) return;
    resetDialogOpen = false;
    docs[active].resetting = true;
    docs[active].error = '';
    docs[active].success = '';
    try {
      const res = await api.delete<LegalResponse>(
        `/api/admin/legal/${active}`,
      );
      docs[active].serverMarkdown = res.markdown;
      docs[active].isCustom = res.isCustom;
      docs[active].draft = res.markdown;
      docs[active].success = 'Reset to the default content.';
    } catch (err) {
      docs[active].error = apiErrorMessage(err, 'Failed to reset content.');
    } finally {
      docs[active].resetting = false;
    }
  }

  function discardDraft() {
    docs[active].draft = current.serverMarkdown;
    docs[active].error = '';
    docs[active].success = '';
  }

  const activeTitle = $derived(
    active === 'privacy' ? 'Privacy Policy' : 'Terms of Use',
  );
  const activePublicPath = $derived(`/${active}`);
</script>

<svelte:head><title>Legal · Admin | CLUB</title></svelte:head>

<h1 class="title">Legal pages</h1>
<p class="subtitle">
  Customize the <strong>Privacy Policy</strong> and <strong>Terms of Use</strong>
  shown at <code>/privacy</code> and <code>/terms</code>. Until you save
  your own version, the defaults that ship with CLUB are served.
</p>

{#if !canEdit}
  <div class="lock">
    <h2>Owner access required</h2>
    <p>
      Only the <strong>server owner</strong> can edit the legal pages.
      Regular admins can view this screen but cannot make changes.
    </p>
  </div>
{/if}

<div class="doc-tabs" role="tablist" aria-label="Which document to edit">
  <button
    type="button"
    role="tab"
    aria-selected={active === 'privacy'}
    class="doc-tab"
    class:active={active === 'privacy'}
    onclick={() => { active = 'privacy'; mode = 'edit'; }}
  >
    Privacy Policy
    {#if docs.privacy.isCustom}<span class="pill">Custom</span>{/if}
  </button>
  <button
    type="button"
    role="tab"
    aria-selected={active === 'terms'}
    class="doc-tab"
    class:active={active === 'terms'}
    onclick={() => { active = 'terms'; mode = 'edit'; }}
  >
    Terms of Use
    {#if docs.terms.isCustom}<span class="pill">Custom</span>{/if}
  </button>
</div>

<section class="card">
  <header class="card-head">
    <div>
      <h2>{activeTitle}</h2>
      <p class="head-sub">
        {#if current.loading}
          Loading…
        {:else if current.isCustom}
          Custom version is live. <a href={activePublicPath} target="_blank" rel="noopener noreferrer">View public page ↗</a>
        {:else}
          Using the bundled default. <a href={activePublicPath} target="_blank" rel="noopener noreferrer">View public page ↗</a>
        {/if}
      </p>
    </div>

    <div class="mode-switch" role="tablist" aria-label="Edit or preview">
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'edit'}
        class="mode-btn"
        class:active={mode === 'edit'}
        onclick={() => (mode = 'edit')}
      >
        Edit
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'preview'}
        class="mode-btn"
        class:active={mode === 'preview'}
        onclick={() => (mode = 'preview')}
      >
        Preview
      </button>
    </div>
  </header>

  {#if current.error}
    <InlineMessage message={current.error} tone="error" />
  {/if}
  {#if current.success}
    <InlineMessage message={current.success} tone="success" />
  {/if}

  {#if mode === 'edit'}
    <textarea
      class="editor"
      spellcheck="false"
      bind:value={docs[active].draft}
      placeholder="Write markdown here…"
      disabled={!canEdit || current.loading}
    ></textarea>
    <p class="hint">
      Supports GitHub-flavored markdown. Headings, links, lists, tables,
      and code blocks render the same as package READMEs.
    </p>
  {:else}
    <div class="preview">
      {#if current.draft.trim().length === 0}
        <p class="preview-empty">Nothing to preview yet.</p>
      {:else}
        <MarkdownRenderer content={current.draft} />
      {/if}
    </div>
  {/if}

  <footer class="card-foot">
    <div class="left-actions">
      <Button
        variant="outline"
        disabled={!canEdit || !current.isCustom || current.resetting || current.saving}
        onclick={() => (resetDialogOpen = true)}
      >
        Reset to default
      </Button>
    </div>

    <div class="right-actions">
      <Button
        variant="outline"
        disabled={!dirty || current.saving}
        onclick={discardDraft}
      >
        Discard changes
      </Button>
      <Button
        disabled={!canEdit || !dirty || current.saving}
        onclick={save}
      >
        {current.saving ? 'Saving…' : 'Save changes'}
      </Button>
    </div>
  </footer>
</section>

<Dialog
  bind:open={resetDialogOpen}
  title="Reset to the default?"
  description={`The current ${activeTitle.toLowerCase()} will be replaced with the default text that ships with CLUB. You can re-customize it at any time.`}
  confirmLabel="Reset"
  confirmVariant="destructive"
  busy={current.resetting}
  onConfirm={confirmReset}
/>

<style>
  .title {
    font-size: 1.375rem;
    font-weight: 700;
    margin: 0 0 0.5rem;
  }
  .subtitle {
    margin: 0 0 1.5rem;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    line-height: 1.6;
    max-width: 48rem;
  }
  .subtitle code {
    padding: 1px 6px;
    background: var(--pub-code-background);
    border: 1px solid var(--pub-code-border);
    border-radius: 4px;
    font-family: var(--font-mono);
    font-size: 0.82em;
    color: var(--pub-code-text-color);
  }

  .lock {
    margin-bottom: 1.25rem;
    padding: 1rem 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--muted);
    color: var(--muted-foreground);
  }
  .lock h2 {
    margin: 0 0 0.25rem;
    font-size: 0.9375rem;
    font-weight: 600;
    color: var(--foreground);
  }
  .lock p {
    margin: 0;
    font-size: 0.8125rem;
    line-height: 1.5;
  }

  .doc-tabs {
    display: flex;
    gap: 0.25rem;
    border-bottom: 1px solid var(--border);
    margin-bottom: 1.25rem;
  }
  .doc-tab {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.75rem 1rem;
    background: transparent;
    border: none;
    border-bottom: 2px solid transparent;
    margin-bottom: -1px;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    font-weight: 500;
    cursor: pointer;
    transition: color 0.12s, border-color 0.12s;
  }
  .doc-tab:hover { color: var(--foreground); }
  .doc-tab.active {
    color: var(--primary);
    border-bottom-color: var(--primary);
  }
  .pill {
    display: inline-flex;
    align-items: center;
    padding: 1px 8px;
    background: var(--accent);
    color: var(--accent-foreground);
    border-radius: 999px;
    font-size: 0.6875rem;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .card {
    padding: 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
  }

  .card-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
    margin-bottom: 1rem;
    flex-wrap: wrap;
  }
  .card-head h2 {
    margin: 0 0 0.25rem;
    font-size: 1.0625rem;
    font-weight: 600;
  }
  .head-sub {
    margin: 0;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
  }
  .head-sub a {
    color: var(--pub-link-text-color);
    text-decoration: none;
  }
  .head-sub a:hover { text-decoration: underline; }

  .mode-switch {
    display: inline-flex;
    padding: 2px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--muted);
  }
  .mode-btn {
    padding: 0.35rem 0.75rem;
    border: none;
    background: transparent;
    color: var(--muted-foreground);
    font-size: 0.8125rem;
    font-weight: 500;
    border-radius: 6px;
    cursor: pointer;
    transition: background 0.12s, color 0.12s;
  }
  .mode-btn:hover { color: var(--foreground); }
  .mode-btn.active {
    background: var(--card);
    color: var(--foreground);
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
  }

  .editor {
    width: 100%;
    min-height: 26rem;
    padding: 0.9rem 1rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    color: var(--foreground);
    font-family: var(--font-mono);
    font-size: 0.85rem;
    line-height: 1.55;
    resize: vertical;
    outline: none;
    box-sizing: border-box;
    margin-top: 0.5rem;
  }
  .editor:focus {
    border-color: var(--primary);
    box-shadow: 0 0 0 3px var(--ring);
  }
  .editor:disabled {
    opacity: 0.7;
    cursor: not-allowed;
  }

  .hint {
    margin: 0.5rem 0 0;
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }

  .preview {
    min-height: 26rem;
    padding: 1.25rem 1.5rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    margin-top: 0.5rem;
    overflow-wrap: break-word;
  }
  .preview-empty {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    text-align: center;
  }

  .card-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    margin-top: 1.25rem;
    padding-top: 1rem;
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
  }
  .right-actions {
    display: flex;
    gap: 0.5rem;
    align-items: center;
  }
</style>
