<script lang="ts">
  /**
   * Package visibility control: the dependency-closure review and the
   * confirmed flip.
   *
   * Kept out of _PackageView.svelte because this is the one control in
   * the app that can put source code on the internet, and it should be
   * readable on its own rather than found inside a 3700-line file.
   *
   * The flow is deliberately two-step. The preview endpoint is
   * side-effect free and answers "what would this do"; only after the
   * operator has seen the closure, the version counts, the bytes, and
   * (for the reverse direction) what breaks, does the apply call happen.
   * Both steps live in one modal: the review and the typed confirmation
   * belong to the same decision, and splitting them across a dialog and
   * a second dialog made the second one look like a formality.
   *
   * Styles are local on purpose. This component used to borrow
   * `.admin-section` / `.option-desc` / `.uploader-add-btn` from
   * _PackageView.svelte, which Svelte scopes to that component, so the
   * classes matched nothing here and the whole section rendered as bare
   * text.
   */
  import { api, apiErrorMessage } from '$lib/api/client';
  import Button from '$lib/components/ui/Button.svelte';
  import Dialog from '$lib/components/ui/Dialog.svelte';

  interface ClosureNode {
    package: string;
    visibility: 'public' | 'private';
    exists: boolean;
    isTarget: boolean;
    versionCount: number;
    totalBytes: number;
    requiredBy: string[];
  }

  interface UnresolvableVersion {
    package: string;
    version: string;
    blockedBy: string[];
  }

  interface AmbiguousDep {
    package: string;
    version: string;
    dependency: string;
    constraint: string | null;
  }

  interface DependentPath {
    package: string;
    path: string[];
  }

  interface Preview {
    package: string;
    target: 'public' | 'private';
    current: 'public' | 'private';
    closure: ClosureNode[];
    selected: string[];
    devOnly: ClosureNode[];
    ambiguousBareDependencies: AmbiguousDep[];
    unresolvableVersions: UnresolvableVersion[];
    publicDependents: DependentPath[];
    blockedReason: string | null;
  }

  interface Props {
    packageName: string;
  }

  let { packageName }: Props = $props();

  let loading = $state(true);
  /** The preview round trip that opens the dialog. */
  let opening = $state(false);
  /** A selection round trip. Freezes the tree, but not the dialog. */
  let refreshing = $state(false);
  /** The apply call. Freezes the dialog, Cancel included. */
  let applying = $state(false);

  let message = $state('');
  let error = $state('');
  /**
   * A failed analysis. Held apart from [applyError] because the two mean
   * opposite things for the Confirm button: a failed refresh leaves stale
   * numbers on screen and must block it, while a failed apply is exactly
   * the case where retrying is reasonable.
   */
  let previewError = $state('');
  /** A failed apply. Shown in the dialog; does not block a retry. */
  let applyError = $state('');

  let visibility = $state<'public' | 'private'>('private');
  let changedAt = $state<string | null>(null);
  let publicPackagesEnabled = $state(false);
  let permittedByEnvironment = $state(false);
  let canManage = $state(false);

  let preview = $state<Preview | null>(null);
  let selected = $state<Set<string>>(new Set());
  /**
   * Bound to the dialog rather than derived from `preview`, because
   * `Dialog` writes `open = false` itself when dismissed via Escape or
   * the backdrop. A derived would be reverted on the next read and the
   * dialog would refuse to close.
   */
  let dialogOpen = $state(false);

  /**
   * Response-identity counters. Every request records the counter it was
   * issued under and drops itself if the counter has moved on, so a
   * response that outlives what it was for cannot overwrite live state.
   *
   * Without them, navigating from package A to package B mid-flight lets
   * A's closure land under B's title, and a cancelled refresh can
   * repopulate the next dialog with the selection that was abandoned.
   */
  let stateSeq = 0;
  let previewSeq = 0;

  const isPublic = $derived(visibility === 'public');
  const goingPublic = $derived(preview?.target === 'public');

  async function loadState() {
    const seq = ++stateSeq;
    loading = true;
    error = '';
    try {
      const data = await api.get<any>(`/api/packages/${packageName}/visibility`);
      if (seq !== stateSeq) return;
      visibility = data.visibility;
      changedAt = data.changedAt ?? null;
      publicPackagesEnabled = !!data.publicPackagesEnabled;
      permittedByEnvironment = !!data.permittedByEnvironment;
      canManage = !!data.canManage;
    } catch (e) {
      if (seq !== stateSeq) return;
      error = apiErrorMessage(e, 'Failed to load visibility state.');
    } finally {
      if (seq === stateSeq) loading = false;
    }
  }

  /**
   * Abandon the review and invalidate anything still in flight for it.
   *
   * The busy flags are cleared here rather than left to their own
   * `finally`, because bumping the counter is exactly what stops those
   * `finally` blocks from touching state.
   */
  function resetPreview() {
    previewSeq++;
    opening = false;
    refreshing = false;
    preview = null;
    selected = new Set();
    previewError = '';
    applyError = '';
  }

  $effect(() => {
    packageName;
    // This component is not keyed on the package, so a route change swaps
    // `packageName` under a dialog that may already be open on the old
    // one. Tear the review down before loading the new package's state.
    resetPreview();
    dialogOpen = false;
    message = '';
    loadState();
  });

  async function openPreview(target: 'public' | 'private') {
    const seq = ++previewSeq;
    opening = true;
    error = '';
    message = '';
    previewError = '';
    applyError = '';
    try {
      const data = await api.post<Preview>(
        `/api/packages/${packageName}/visibility/preview`,
        { visibility: target }
      );
      if (seq !== previewSeq) return;
      preview = data;
      selected = new Set(data.selected);
      dialogOpen = true;
    } catch (e) {
      if (seq !== previewSeq) return;
      error = apiErrorMessage(e, 'Could not analyse this change.');
    } finally {
      if (seq === previewSeq) opening = false;
    }
  }

  /**
   * Recompute the preview whenever the selection changes, so the
   * consequences shown are always the consequences of what is actually
   * ticked. Doing this client-side would mean reimplementing the
   * resolvability rule in a second place, which is how the two drift.
   */
  async function refreshPreview() {
    if (!preview) return;
    const seq = ++previewSeq;
    refreshing = true;
    previewError = '';
    applyError = '';
    try {
      const data = await api.post<Preview>(
        `/api/packages/${packageName}/visibility/preview`,
        { visibility: preview.target, closure: [...selected] }
      );
      if (seq !== previewSeq) return;
      preview = data;
      selected = new Set(data.selected);
    } catch (e) {
      if (seq !== previewSeq) return;
      previewError = apiErrorMessage(e, 'Could not analyse this change.');
    } finally {
      if (seq === previewSeq) refreshing = false;
    }
  }

  function toggle(name: string) {
    // The target is not optional: deselecting it would make the whole
    // action a no-op wearing the shape of a change.
    if (name === packageName) return;
    const next = new Set(selected);
    if (next.has(name)) next.delete(name);
    else next.add(name);
    selected = next;
    refreshPreview();
  }

  function formatBytes(n: number): string {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }

  /**
   * The selected packages that actually change.
   *
   * `apply` skips nodes it cannot find and nodes already at the target,
   * so counting every selected node promises more than happens: a
   * confirm button offering to publish a package that is not even on
   * this server, followed by a success message claiming it was.
   */
  let flipping = $derived.by(() => {
    if (!preview) return [] as ClosureNode[];
    const target = preview.target;
    return preview.closure.filter(
      (n) => selected.has(n.package) && n.exists && n.visibility !== target
    );
  });

  let totals = $derived({
    packages: flipping.length,
    versions: flipping.reduce((a, n) => a + n.versionCount, 0),
    bytes: flipping.reduce((a, n) => a + n.totalBytes, 0)
  });

  /** Public dependents that were left out and will stop resolving. */
  let breaking = $derived(
    preview?.publicDependents.filter((d) => !selected.has(d.package)) ?? []
  );

  async function apply() {
    if (!preview) return;
    const target = preview.target;
    // Read, not bumped: this call belongs to the review that is open, and
    // anything that ends that review (cancel, a route change) should also
    // stop its result from landing.
    const seq = previewSeq;

    applying = true;
    applyError = '';
    try {
      await api.put<any>(`/api/packages/${packageName}/visibility`, {
        visibility: target,
        closure: [...selected],
        confirm: packageName,
        // Only accept breakage that was actually shown. If the server's
        // own recheck finds dependents this dialog never rendered (a
        // stale preview, a publish landing mid-review), an unconditional
        // flag would wave them through silently.
        acceptBreakage: target === 'private' && breaking.length > 0
      });
      if (seq !== previewSeq) return;
      const others = totals.packages - 1;
      message =
        target === 'public'
          ? others > 0
            ? `${packageName} and ${others} dependency package${others === 1 ? '' : 's'} are now public.`
            : `${packageName} is now public.`
          : others > 0
            ? `${packageName} and ${others} package${others === 1 ? '' : 's'} are now private.`
            : `${packageName} is now private.`;
      dialogOpen = false;
      resetPreview();
      await loadState();
    } catch (e) {
      if (seq !== previewSeq) return;
      applyError = apiErrorMessage(e, 'Could not apply the change.');
    } finally {
      applying = false;
    }
  }

  /** Dialog dismissal: backdrop, Escape, or the Cancel button. */
  function cancel() {
    resetPreview();
  }
</script>

<section class="vis-section" class:is-public={isPublic}>
  <div class="vis-head">
    <div class="vis-title">
      <h3>Visibility</h3>
      {#if !loading}
        <span class="vis-status" class:public={isPublic}>
          {isPublic ? 'Public' : 'Private'}
        </span>
      {/if}
    </div>

    {#if loading}
      <p class="vis-desc">Loading...</p>
    {:else}
      <p class="vis-desc">
        {#if isPublic}
          Anyone can view and download this package without an account, and
          <code>dart pub get</code> resolves it with no token.
        {:else}
          Credentials are required to view or download this package.
        {/if}
        {#if changedAt}
          <span class="vis-meta"
            >Changed {new Date(changedAt).toLocaleString()}.</span
          >
        {/if}
      </p>
    {/if}
  </div>

  {#if !loading}
    {#if !permittedByEnvironment}
      <p class="vis-note">
        Public packages are disabled for this deployment. A server operator must
        set <code>PUBLIC_PACKAGES_ENABLED=true</code> in the server environment
        before any package can be shared publicly.
      </p>
    {:else if !publicPackagesEnabled}
      <p class="vis-note">
        Public packages are turned off for this server. A server admin can
        enable them under Admin &gt; Settings.
      </p>
    {/if}

    {#if error}
      <p class="vis-error">{error}</p>
    {/if}
    {#if message}
      <p class="vis-ok">{message}</p>
    {/if}

    {#if canManage}
      <div class="vis-cta">
        <Button
          variant={isPublic ? 'outline' : 'default'}
          disabled={opening}
          onclick={() => openPreview(isPublic ? 'private' : 'public')}
        >
          {#if opening}
            Analysing...
          {:else}
            {isPublic ? 'Make private' : 'Make public'}
          {/if}
        </Button>
        <span class="vis-cta-hint">
          {isPublic
            ? 'Review which packages come back with it before anything changes.'
            : 'You will review the full dependency closure before anything changes.'}
        </span>
      </div>
    {/if}
  {/if}
</section>

<Dialog
  bind:open={dialogOpen}
  size="lg"
  title={goingPublic
    ? `Make ${packageName} public?`
    : `Make ${packageName} private?`}
  confirmLabel={goingPublic
    ? `Make ${totals.packages} package${totals.packages === 1 ? '' : 's'} public`
    : `Make ${totals.packages} package${totals.packages === 1 ? '' : 's'} private`}
  confirmVariant="destructive"
  busy={applying}
  confirmDisabled={refreshing ||
    !!previewError ||
    !!preview?.blockedReason ||
    totals.packages === 0}
  confirmText={packageName}
  onConfirm={apply}
  onCancel={cancel}
>
  {#snippet body()}
    {#if preview}
      <div class="dlg" class:frozen={refreshing}>
        {#if goingPublic}
          <p class="dlg-lede">
            A public package whose club-hosted dependency stayed private cannot
            be resolved by anyone without a token, so the whole dependency
            closure is selected by default. Deselect anything you want to keep
            private and the affected versions are listed below.
          </p>
        {:else}
          <p class="dlg-lede">
            Select the packages that went public alongside
            <code>{packageName}</code> and should come back with it.
          </p>
        {/if}

        <ul class="vis-tree">
          {#each preview.closure as node (node.package)}
            <li class:vis-target={node.isTarget}>
              <label>
                <input
                  type="checkbox"
                  checked={selected.has(node.package)}
                  disabled={node.isTarget || refreshing || applying}
                  onchange={() => toggle(node.package)}
                />
                <span class="vis-name">{node.package}</span>
                {#if node.isTarget}
                  <span class="vis-badge">this package</span>
                {:else if node.visibility === 'public'}
                  <span class="vis-badge vis-badge-ok">already public</span>
                {/if}
                {#if !node.exists}
                  <span class="vis-badge vis-badge-warn">not on this server</span
                  >
                {/if}
                <span class="vis-detail">
                  {node.versionCount} version{node.versionCount === 1
                    ? ''
                    : 's'},
                  {formatBytes(node.totalBytes)}
                </span>
              </label>
              {#if node.requiredBy.length > 0}
                <div class="vis-why">required by {node.requiredBy.join(', ')}</div>
              {/if}
            </li>
          {/each}
        </ul>

        <div class="vis-totals">
          <strong
            >{totals.packages} package{totals.packages === 1 ? '' : 's'}</strong
          >
          <span>·</span>
          <span
            >{totals.versions} version{totals.versions === 1 ? '' : 's'}</span
          >
          <span>·</span>
          <span>{formatBytes(totals.bytes)} of archives</span>
        </div>

        {#if preview.unresolvableVersions.length > 0}
          <div class="vis-warn">
            <strong>These versions will be hidden from anonymous clients</strong>
            <p>
              They declare a club-hosted dependency that stays private, so
              <code>dart pub get</code> without a token will not select them.
              Their archives remain downloadable; only the version list omits
              them.
            </p>
            <ul>
              {#each preview.unresolvableVersions as v (v.package + v.version)}
                <li>
                  <code>{v.package} {v.version}</code> needs {v.blockedBy.join(
                    ', '
                  )}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        {#if preview.publicDependents.length > 0 && !goingPublic}
          <div class="vis-warn">
            <strong>Public packages that depend on this</strong>
            <ul>
              {#each preview.publicDependents as d (d.package)}
                <li>
                  <code>{d.path.join(' → ')}</code>
                  {#if selected.has(d.package)}
                    <span class="vis-badge vis-badge-ok">included</span>
                  {:else}
                    <span class="vis-badge vis-badge-warn">will break</span>
                  {/if}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        {#if preview.devOnly.length > 0}
          <div class="vis-info">
            <strong>Dev dependencies (not required)</strong>
            <p>
              These are reachable only through <code>dev_dependencies</code>. A
              dependency's dev dependencies are never resolved by consumers, so
              leaving them private breaks nothing downstream.
            </p>
            <p class="vis-list">
              {preview.devOnly.map((n) => n.package).join(', ')}
            </p>
          </div>
        {/if}

        {#if preview.ambiguousBareDependencies.length > 0}
          <div class="vis-info">
            <strong>Ambiguous dependencies</strong>
            <p>
              These are declared without a <code>hosted:</code> URL but share a
              name with a package on this server. Anonymous consumers resolve
              them from pub.dev regardless, so making the local package public
              would not help. Add an explicit <code>hosted:</code> URL to the
              pubspec if you meant the club-hosted one.
            </p>
            <ul>
              {#each preview.ambiguousBareDependencies as a (a.package + a.version + a.dependency)}
                <li>
                  <code>{a.package} {a.version}</code> depends on
                  <code>{a.dependency} {a.constraint ?? ''}</code>
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        <!-- The consequences, last and unmissable: this is the copy the
             typed confirmation directly below is asking about. -->
        {#if goingPublic}
          <div class="vis-consequences">
            <strong>Before you confirm</strong>
            <ul>
              <li>This cannot be undone for anything already downloaded.</li>
              <li>
                <strong>Every</strong> version becomes downloadable, not just the
                latest. Old versions may contain committed secrets, internal
                hostnames, or customer names that were acceptable while this
                registry was private.
              </li>
              <li>
                A pub archive is source, not a compiled artifact. README,
                CHANGELOG, example code, screenshots, and generated API docs go
                with it.
              </li>
              <li>
                Storage URLs already handed out stay valid for a short period
                after any later revert.
              </li>
            </ul>
          </div>
        {:else if breaking.length > 0}
          <div class="vis-consequences">
            <strong>Before you confirm</strong>
            <ul>
              <li>
                {breaking.length} public package{breaking.length === 1
                  ? ''
                  : 's'} not included above will stop resolving for anonymous users.
              </li>
              <li>This does not un-publish anything already downloaded.</li>
            </ul>
          </div>
        {/if}

        {#if preview.blockedReason}
          <div class="vis-blocked">{preview.blockedReason}</div>
        {/if}

        {#if previewError}
          <div class="vis-blocked">
            {previewError} The numbers above are from the previous selection,
            so confirming is disabled until this succeeds.
          </div>
        {/if}

        {#if applyError}
          <div class="vis-blocked">{applyError}</div>
        {/if}
      </div>
    {/if}
  {/snippet}

  {#snippet typedPrompt()}
    Type <code>"{packageName}"</code> to confirm.
  {/snippet}
</Dialog>

<style>
  /* A card rather than the plain `.admin-section` rule its siblings use:
     this is the only control on the page that can publish source code to
     the internet, and it should not read as one more option row. */
  .vis-section {
    border: 1px solid var(--border);
    border-left: 3px solid var(--muted-foreground);
    border-radius: 10px;
    background: var(--card);
    padding: 18px 20px;
    margin-bottom: 24px;
  }

  .vis-section.is-public {
    border-left-color: var(--primary);
  }

  .vis-head {
    margin-bottom: 4px;
  }

  .vis-title {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 6px;
  }

  .vis-title h3 {
    font-size: 16px;
    font-weight: 600;
    margin: 0;
    color: var(--pub-heading-text-color);
  }

  .vis-status {
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    padding: 3px 8px;
    border-radius: 999px;
    background: var(--muted);
    color: var(--muted-foreground);
    border: 1px solid var(--border);
  }

  .vis-status.public {
    background: var(--accent);
    color: var(--primary);
    border-color: color-mix(in srgb, var(--primary) 35%, transparent);
  }

  .vis-desc {
    font-size: 13px;
    color: var(--pub-muted-text-color);
    line-height: 1.5;
    margin: 0;
  }

  .vis-meta {
    color: var(--muted-foreground);
    margin-left: 4px;
  }

  .vis-note,
  .vis-error,
  .vis-ok {
    font-size: 13px;
    margin: 12px 0 0;
    padding: 8px 10px;
    border-radius: 8px;
  }

  .vis-note {
    background: var(--muted);
    color: var(--muted-foreground);
  }

  .vis-error {
    background: color-mix(in srgb, var(--destructive) 12%, transparent);
    color: var(--destructive);
  }

  .vis-ok {
    background: color-mix(in srgb, var(--success) 12%, transparent);
    color: var(--success);
  }

  .vis-cta {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
    margin-top: 16px;
  }

  .vis-cta-hint {
    font-size: 12px;
    color: var(--muted-foreground);
  }

  /* ── Dialog body ─────────────────────────────────────────────── */

  .dlg-lede {
    margin: 0;
    color: var(--muted-foreground);
    line-height: 1.5;
  }

  /* A selection round trip is in flight. The tree still reads, but it
     is not accepting input, and the numbers below it are stale. */
  .dlg.frozen {
    opacity: 0.6;
    pointer-events: none;
  }

  .vis-tree {
    list-style: none;
    margin: 12px 0;
    padding: 0;
    border: 1px solid var(--border);
    border-radius: 8px;
  }

  .vis-tree li {
    padding: 8px 12px;
    border-bottom: 1px solid var(--border);
  }

  .vis-tree li:last-child {
    border-bottom: none;
  }

  .vis-tree label {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 14px;
    cursor: pointer;
  }

  .vis-target {
    background: var(--muted);
  }

  .vis-target .vis-name {
    font-weight: 700;
  }

  .vis-name {
    font-family: var(--font-mono, monospace);
  }

  .vis-detail {
    color: var(--muted-foreground);
    font-size: 12px;
    margin-left: auto;
    white-space: nowrap;
  }

  .vis-why {
    font-size: 12px;
    color: var(--muted-foreground);
    margin-left: 26px;
  }

  .vis-totals {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-wrap: wrap;
    font-size: 13px;
    color: var(--muted-foreground);
    padding: 8px 12px;
    border-radius: 8px;
    background: var(--muted);
  }

  .vis-totals strong {
    color: var(--foreground);
  }

  .vis-badge {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    padding: 2px 6px;
    border-radius: 3px;
    background: var(--accent);
    color: var(--primary);
    white-space: nowrap;
  }

  .vis-badge-ok {
    background: color-mix(in srgb, var(--success) 15%, transparent);
    color: var(--success);
  }

  .vis-badge-warn {
    background: color-mix(in srgb, var(--destructive) 15%, transparent);
    color: var(--destructive);
  }

  .vis-warn,
  .vis-info,
  .vis-consequences,
  .vis-blocked {
    margin-top: 12px;
    padding: 10px 12px;
    border-radius: 8px;
    font-size: 13px;
  }

  .vis-warn {
    background: color-mix(in srgb, var(--destructive) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
  }

  .vis-info {
    background: var(--background);
    border: 1px solid var(--border);
  }

  .vis-consequences {
    background: color-mix(in srgb, var(--warning) 10%, transparent);
    border: 1px solid color-mix(in srgb, var(--warning) 30%, transparent);
  }

  .vis-blocked {
    background: color-mix(in srgb, var(--destructive) 12%, transparent);
    color: var(--destructive);
    font-weight: 500;
  }

  .vis-warn ul,
  .vis-info ul,
  .vis-consequences ul {
    margin: 6px 0 0;
    padding-left: 18px;
    line-height: 1.55;
  }

  .vis-consequences li + li {
    margin-top: 4px;
  }

  .vis-warn p,
  .vis-info p {
    margin: 4px 0 0;
    color: var(--muted-foreground);
  }

  .vis-list {
    font-family: var(--font-mono, monospace);
  }
</style>
