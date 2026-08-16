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
   */
  import { api, apiErrorMessage } from '$lib/api/client';
  import { confirmDialog } from '$lib/stores/confirm';

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
  let busy = $state(false);
  let message = $state('');
  let error = $state('');

  let visibility = $state<'public' | 'private'>('private');
  let changedAt = $state<string | null>(null);
  let publicPackagesEnabled = $state(false);
  let permittedByEnvironment = $state(false);
  let canManage = $state(false);

  let preview = $state<Preview | null>(null);
  let selected = $state<Set<string>>(new Set());

  async function loadState() {
    loading = true;
    error = '';
    try {
      const data = await api.get<any>(`/api/packages/${packageName}/visibility`);
      visibility = data.visibility;
      changedAt = data.changedAt ?? null;
      publicPackagesEnabled = !!data.publicPackagesEnabled;
      permittedByEnvironment = !!data.permittedByEnvironment;
      canManage = !!data.canManage;
    } catch (e) {
      error = apiErrorMessage(e, 'Failed to load visibility state.');
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    packageName;
    loadState();
  });

  async function openPreview(target: 'public' | 'private') {
    busy = true;
    error = '';
    message = '';
    try {
      const data = await api.post<Preview>(
        `/api/packages/${packageName}/visibility/preview`,
        { visibility: target }
      );
      preview = data;
      selected = new Set(data.selected);
    } catch (e) {
      error = apiErrorMessage(e, 'Could not analyse this change.');
    } finally {
      busy = false;
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
    busy = true;
    try {
      const data = await api.post<Preview>(
        `/api/packages/${packageName}/visibility/preview`,
        { visibility: preview.target, closure: [...selected] }
      );
      preview = data;
      selected = new Set(data.selected);
    } catch (e) {
      error = apiErrorMessage(e, 'Could not analyse this change.');
    } finally {
      busy = false;
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

  let totals = $derived.by(() => {
    if (!preview) return { packages: 0, versions: 0, bytes: 0 };
    const nodes = preview.closure.filter((n) => selected.has(n.package));
    return {
      packages: nodes.length,
      versions: nodes.reduce((a, n) => a + n.versionCount, 0),
      bytes: nodes.reduce((a, n) => a + n.totalBytes, 0)
    };
  });

  async function apply() {
    if (!preview) return;
    const target = preview.target;

    const description =
      target === 'public'
        ? [
            `${totals.packages} package(s), ${totals.versions} version(s), ` +
              `${formatBytes(totals.bytes)} of archives will become readable ` +
              `by anyone with no account.`,
            '',
            'This cannot be undone for anything already downloaded.',
            '',
            'EVERY version becomes downloadable, not just the latest. Old ' +
              'versions may contain committed secrets, internal hostnames, ' +
              'or customer names that were acceptable while this registry ' +
              'was private.',
            '',
            'A pub archive is source, not a compiled artifact. README, ' +
              'CHANGELOG, example code, screenshots, and generated API docs ' +
              'go with it.',
            '',
            'Storage URLs already handed out stay valid for a short period ' +
              'after any later revert.'
          ].join('\n')
        : [
            `${preview.publicDependents.length} public package(s) depend on ` +
              `${packageName}.`,
            '',
            ...preview.publicDependents
              .filter((d) => !selected.has(d.package))
              .map((d) => `  ${d.path.join(' -> ')}`),
            '',
            'Any of those not included above will stop resolving for ' +
              'anonymous users. This does not un-publish anything already ' +
              'downloaded.'
          ].join('\n');

    const ok = await confirmDialog({
      title:
        target === 'public'
          ? `Make ${packageName} public?`
          : `Make ${packageName} private?`,
      description,
      confirmLabel: target === 'public' ? 'Make public' : 'Make private',
      confirmVariant: 'destructive',
      // Typed confirmation. Deliberate friction: this is irreversible for
      // bytes already served.
      confirmText: packageName
    });
    if (!ok) return;

    busy = true;
    error = '';
    try {
      await api.put<any>(`/api/packages/${packageName}/visibility`, {
        visibility: target,
        closure: [...selected],
        confirm: packageName,
        acceptBreakage: target === 'private'
      });
      message =
        target === 'public'
          ? `${packageName} and ${totals.packages - 1} dependency package(s) are now public.`
          : `${packageName} is now private.`;
      preview = null;
      await loadState();
    } catch (e) {
      error = apiErrorMessage(e, 'Could not apply the change.');
    } finally {
      busy = false;
    }
  }

  function cancel() {
    preview = null;
    error = '';
  }
</script>

<section class="admin-section">
  <h3>Visibility</h3>

  {#if loading}
    <p class="option-desc">Loading...</p>
  {:else}
    <div class="option-group">
      <p class="option-desc">
        {#if visibility === 'public'}
          <strong>Public.</strong> Anyone can view and download this package
          without an account, and <code>dart pub get</code> resolves it with no
          token.
        {:else}
          <strong>Private.</strong> Credentials are required to view or
          download this package.
        {/if}
        {#if changedAt}
          <span class="vis-meta">Changed {new Date(changedAt).toLocaleString()}.</span>
        {/if}
      </p>

      {#if !permittedByEnvironment}
        <p class="vis-note">
          Public packages are disabled for this deployment. A server operator
          must set <code>PUBLIC_PACKAGES_ENABLED=true</code> in the server
          environment before any package can be shared publicly.
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

      {#if canManage && !preview}
        <button
          class="uploader-add-btn"
          disabled={busy}
          onclick={() => openPreview(visibility === 'public' ? 'private' : 'public')}
        >
          {visibility === 'public' ? 'Make private' : 'Make public'}
        </button>
      {/if}
    </div>

    {#if preview}
      <div class="vis-preview">
        {#if preview.target === 'public'}
          <h4>These packages will become public</h4>
          <p class="option-desc">
            A public package whose club-hosted dependency stayed private
            cannot be resolved by anyone without a token, so the whole
            dependency closure is selected by default. Deselect anything you
            want to keep private, and the affected versions are listed below.
          </p>
        {:else}
          <h4>Also make these private</h4>
          <p class="option-desc">
            Select the packages that went public alongside {packageName} and
            should come back with it.
          </p>
        {/if}

        <ul class="vis-tree">
          {#each preview.closure as node (node.package)}
            <li class:vis-target={node.isTarget}>
              <label>
                <input
                  type="checkbox"
                  checked={selected.has(node.package)}
                  disabled={node.isTarget || busy}
                  onchange={() => toggle(node.package)}
                />
                <span class="vis-name">{node.package}</span>
                {#if node.isTarget}
                  <span class="vis-badge">this package</span>
                {:else if node.visibility === 'public'}
                  <span class="vis-badge vis-badge-ok">already public</span>
                {/if}
                {#if !node.exists}
                  <span class="vis-badge vis-badge-warn">not on this server</span>
                {/if}
                <span class="vis-detail">
                  {node.versionCount} version{node.versionCount === 1 ? '' : 's'},
                  {formatBytes(node.totalBytes)}
                </span>
              </label>
              {#if node.requiredBy.length > 0}
                <div class="vis-why">required by {node.requiredBy.join(', ')}</div>
              {/if}
            </li>
          {/each}
        </ul>

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
                  <code>{v.package} {v.version}</code> needs {v.blockedBy.join(', ')}
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        {#if preview.publicDependents.length > 0 && preview.target === 'private'}
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
              These are reachable only through <code>dev_dependencies</code>.
              A dependency's dev dependencies are never resolved by consumers,
              so leaving them private breaks nothing downstream.
            </p>
            <p class="vis-list">{preview.devOnly.map((n) => n.package).join(', ')}</p>
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

        {#if preview.blockedReason}
          <div class="vis-blocked">{preview.blockedReason}</div>
        {/if}

        <div class="vis-actions">
          <button class="uploader-add-btn" onclick={cancel} disabled={busy}>
            Cancel
          </button>
          <button
            class="uploader-add-btn vis-apply"
            onclick={apply}
            disabled={busy || !!preview.blockedReason}
          >
            {preview.target === 'public'
              ? `Make ${totals.packages} package(s) public`
              : `Make ${totals.packages} package(s) private`}
          </button>
        </div>
      </div>
    {/if}
  {/if}
</section>

<style>
  .vis-meta {
    color: var(--muted-foreground);
    margin-left: 4px;
  }
  .vis-note,
  .vis-error,
  .vis-ok {
    font-size: 13px;
    margin: 8px 0 0;
    padding: 8px 10px;
    border-radius: 8px;
  }
  .vis-note {
    background: var(--muted);
    color: var(--muted-foreground);
  }
  .vis-error {
    background: color-mix(in srgb, #dc2626 12%, transparent);
    color: #dc2626;
  }
  .vis-ok {
    background: color-mix(in srgb, #16a34a 12%, transparent);
    color: #16a34a;
  }
  .vis-preview {
    margin-top: 16px;
    padding: 16px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--muted);
  }
  .vis-preview h4 {
    margin: 0 0 6px;
    font-size: 15px;
  }
  .vis-tree {
    list-style: none;
    margin: 12px 0;
    padding: 0;
  }
  .vis-tree li {
    padding: 6px 0;
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
  }
  .vis-why {
    font-size: 12px;
    color: var(--muted-foreground);
    margin-left: 26px;
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
  }
  .vis-badge-ok {
    background: color-mix(in srgb, #16a34a 15%, transparent);
    color: #16a34a;
  }
  .vis-badge-warn {
    background: color-mix(in srgb, #dc2626 15%, transparent);
    color: #dc2626;
  }
  .vis-warn,
  .vis-info,
  .vis-blocked {
    margin-top: 12px;
    padding: 10px 12px;
    border-radius: 8px;
    font-size: 13px;
  }
  .vis-warn {
    background: color-mix(in srgb, #dc2626 8%, transparent);
    border: 1px solid color-mix(in srgb, #dc2626 25%, transparent);
  }
  .vis-info {
    background: var(--background);
    border: 1px solid var(--border);
  }
  .vis-blocked {
    background: color-mix(in srgb, #dc2626 12%, transparent);
    color: #dc2626;
    font-weight: 500;
  }
  .vis-warn ul,
  .vis-info ul {
    margin: 6px 0 0;
    padding-left: 18px;
  }
  .vis-warn p,
  .vis-info p {
    margin: 4px 0 0;
    color: var(--muted-foreground);
  }
  .vis-list {
    font-family: var(--font-mono, monospace);
  }
  .vis-actions {
    display: flex;
    gap: 8px;
    margin-top: 16px;
  }
  .vis-apply {
    background: var(--primary);
    color: white;
    border-color: var(--primary);
  }
</style>
