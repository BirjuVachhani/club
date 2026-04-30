<script lang="ts">
  import { api } from '$lib/api/client';
  import { confirmDialog, confirmState } from '$lib/stores/confirm';

  // ── Types ──────────────────────────────────────────────────
  interface SdkInstall {
    id: string;
    channel: string;
    version: string;
    dartVersion: string | null;
    sizeBytes: number | null;
    status: 'cloning' | 'settingUp' | 'ready' | 'failed';
    errorMessage: string | null;
    isDefault: boolean;
    installedAt: string | null;
    createdAt: string;
  }

  interface FlutterRelease {
    version: string;
    channel: string;
    dartVersion: string;
  }

  interface InstallProgress {
    installId: string;
    phase: string;
    error: string | null;
    logs: string[];
  }

  interface InFlightJob {
    packageName: string;
    version: string;
    pid: number;
  }

  interface Settings {
    scoringEnabled: boolean;
    defaultSdkVersion: string | null;
    platform: string;
    availableDiskSpace: number;
    workers: {
      total: number;
      active: number;
      queued: number;
      inFlightJobs?: InFlightJob[];
    };
    coverage: { totalPackages: number; scoredPackages: number };
    discovery: { error: string | null; at: string | null };
  }

  // ── State ──────────────────────────────────────────────────
  let settings = $state<Settings | null>(null);
  let installs = $state<SdkInstall[]>([]);
  let releases = $state<FlutterRelease[]>([]);
  let progress = $state<Record<string, InstallProgress>>({});

  let loading = $state(true);
  let error = $state('');
  let message = $state('');

  // Download form state
  let selectedChannel = $state('stable');
  let selectedRelease = $state<FlutterRelease | null>(null);
  let installPending = $state(false);

  // Collapsible logs state (SDK install logs)
  let expandedLogs = $state<Record<string, boolean>>({});
  let logElements = $state<Record<string, HTMLPreElement>>({});

  // Scoring logs state
  let scoringLogs = $state<string[]>([]);
  let scoringLogsExpanded = $state(false);
  let scoringLogsEl = $state<HTMLPreElement | null>(null);

  // Track which log containers the user has scrolled away from bottom.
  let userScrolledAway = $state<Record<string, boolean>>({});

  function isNearBottom(el: HTMLElement): boolean {
    return el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  }

  function handleLogScroll(id: string, el: HTMLElement) {
    userScrolledAway = { ...userScrolledAway, [id]: !isNearBottom(el) };
  }

  function jumpToBottom(id: string) {
    const el = id === '_scoring' ? scoringLogsEl : logElements[id];
    if (el) {
      el.scrollTop = el.scrollHeight;
      userScrolledAway = { ...userScrolledAway, [id]: false };
    }
  }

  // Auto-scroll logs to bottom when new lines arrive (only if user hasn't scrolled up).
  $effect(() => {
    void progress;
    for (const [id, el] of Object.entries(logElements)) {
      if (el && expandedLogs[id] && !userScrolledAway[id]) {
        el.scrollTop = el.scrollHeight;
      }
    }
  });

  // ── Load data ──────────────────────────────────────────────
  $effect(() => { loadAll(); });

  async function loadAll() {
    try {
      const [settingsData, installsData] = await Promise.all([
        api.get<Settings>('/api/admin/sdk/settings'),
        api.get<{ installs: SdkInstall[] }>('/api/admin/sdk/installs'),
      ]);
      settings = settingsData;
      installs = installsData.installs;
    } catch (e: any) {
      error = e.message ?? 'Failed to load SDK settings.';
    } finally {
      loading = false;
    }
  }

  // ── Scoring toggle ─────────────────────────────────────────
  async function toggleScoring() {
    if (!settings) return;
    const newVal = !settings.scoringEnabled;
    try {
      await api.put('/api/admin/sdk/settings', { scoringEnabled: newVal });
      settings = { ...settings, scoringEnabled: newVal };
      message = newVal ? 'Scoring enabled.' : 'Scoring disabled.';
    } catch {
      message = 'Failed to update scoring setting.';
    }
  }

  // ── Releases ───────────────────────────────────────────────
  let releasesLoading = $state(false);

  $effect(() => {
    void selectedChannel;
    loadReleases();
  });

  async function loadReleases() {
    releasesLoading = true;
    selectedRelease = null;
    try {
      const data = await api.get<{ releases: FlutterRelease[] }>(
        `/api/admin/sdk/releases?channel=${selectedChannel}`,
      );
      // Filter out already-installed versions.
      const installedVersions = new Set(installs.map((i) => i.version));
      releases = data.releases.filter((r) => !installedVersions.has(r.version));
    } catch {
      releases = [];
    } finally {
      releasesLoading = false;
    }
  }

  // ── Install ────────────────────────────────────────────────
  async function startInstall() {
    if (!selectedRelease || installPending) return;
    installPending = true;
    message = '';
    try {
      const install = await api.post<SdkInstall>('/api/admin/sdk/installs', {
        version: selectedRelease.version,
        channel: selectedRelease.channel,
      });
      // Add to installs list, auto-expand logs, and start polling.
      installs = [install, ...installs];
      expandedLogs = { ...expandedLogs, [install.id]: true };
      selectedRelease = null;
    } catch (e: any) {
      message = e.message ?? 'Failed to start install.';
    } finally {
      installPending = false;
    }
  }

  // ── Polling for in-flight installs ─────────────────────────
  $effect(() => {
    const inFlight = installs.filter(
      (i) => i.status === 'cloning' || i.status === 'settingUp',
    );
    if (inFlight.length === 0) return;

    const timer = setInterval(async () => {
      let changed = false;
      for (const install of inFlight) {
        try {
          const p = await api.get<InstallProgress>(
            `/api/admin/sdk/installs/${install.id}/progress`,
          );
          progress = { ...progress, [install.id]: p };
          if (p.phase === 'ready' || p.phase === 'failed') {
            changed = true;
          }
        } catch {
          // ignore polling errors
        }
      }
      if (changed) {
        // Refresh the full list to get updated statuses.
        const data = await api.get<{ installs: SdkInstall[] }>('/api/admin/sdk/installs');
        installs = data.installs;
      }
    }, 2000);
    return () => clearInterval(timer);
  });

  // ── Polling for scoring stats ────────────────────────────────
  $effect(() => {
    if (!settings?.scoringEnabled) return;
    const timer = setInterval(async () => {
      try {
        const data = await api.get<Settings>('/api/admin/sdk/settings');
        if (settings) {
          settings = {
            ...settings,
            workers: data.workers,
            coverage: data.coverage,
            discovery: data.discovery,
          };
        }
      } catch {
        // ignore
      }
    }, 5000);
    return () => clearInterval(timer);
  });

  // ── Polling for scoring logs ───────────────────────────────
  $effect(() => {
    if (!scoringLogsExpanded) return;
    async function fetchLogs() {
      try {
        const data = await api.get<{ lines: string[] }>('/api/admin/sdk/scoring-logs');
        scoringLogs = data.lines;
      } catch { /* ignore */ }
    }
    fetchLogs();
    const timer = setInterval(fetchLogs, 3000);
    return () => clearInterval(timer);
  });

  // Auto-scroll scoring logs to bottom (only if user hasn't scrolled up).
  $effect(() => {
    void scoringLogs;
    if (scoringLogsEl && !userScrolledAway['_scoring']) {
      scoringLogsEl.scrollTop = scoringLogsEl.scrollHeight;
    }
  });

  // ── Actions ────────────────────────────────────────────────
  async function rebuildInstall(id: string) {
    try {
      const install = await api.post<SdkInstall>(`/api/admin/sdk/installs/${id}/rebuild`);
      installs = installs.map((i) => i.id === id ? install : i);
      expandedLogs = { ...expandedLogs, [id]: true };
      message = '';
    } catch (e: any) {
      message = e.message ?? 'Failed to start rebuild.';
    }
  }

  async function setDefault(id: string) {
    try {
      await api.post(`/api/admin/sdk/installs/${id}/set-default`);
      const data = await api.get<{ installs: SdkInstall[] }>('/api/admin/sdk/installs');
      installs = data.installs;
      message = 'Default SDK updated.';
    } catch {
      message = 'Failed to set default.';
    }
  }

  let scanning = $state(false);

  async function scanDisk() {
    if (scanning) return;
    scanning = true;
    message = '';
    try {
      const data = await api.post<{ discovered: SdkInstall[] }>('/api/admin/sdk/scan');
      if (data.discovered.length === 0) {
        message = 'Scan complete. No new SDKs found on disk.';
      } else {
        // Merge discovered installs in front of the list, auto-expand their
        // logs so the admin sees progress, and let the existing in-flight
        // poller pick them up.
        const ids = new Set(data.discovered.map((i) => i.id));
        installs = [
          ...data.discovered,
          ...installs.filter((i) => !ids.has(i.id)),
        ];
        const expanded: Record<string, boolean> = { ...expandedLogs };
        for (const i of data.discovered) expanded[i.id] = true;
        expandedLogs = expanded;
        message = `Discovered ${data.discovered.length} SDK(s) on disk. Rebuilding…`;
      }
      // Refresh settings so the discovery-error card clears on success.
      const fresh = await api.get<Settings>('/api/admin/sdk/settings');
      if (settings) settings = { ...settings, discovery: fresh.discovery };
    } catch (e: any) {
      message = e.message ?? 'Failed to scan SDK directory.';
      // Pull the captured server-side error so the card stays in sync.
      try {
        const fresh = await api.get<Settings>('/api/admin/sdk/settings');
        if (settings) settings = { ...settings, discovery: fresh.discovery };
      } catch {
        // ignore
      }
    } finally {
      scanning = false;
    }
  }

  async function deleteInstall(id: string, version: string) {
    const ok = await confirmDialog({
      title: `Delete Flutter SDK ${version}?`,
      description: 'All SDK files will be removed.',
      confirmLabel: 'Delete',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    try {
      await api.delete(`/api/admin/sdk/installs/${id}`);
      installs = installs.filter((i) => i.id !== id);
      message = `SDK ${version} deleted.`;
    } catch {
      message = 'Failed to delete SDK.';
    }
  }

  function toggleLogs(id: string) {
    expandedLogs = { ...expandedLogs, [id]: !expandedLogs[id] };
  }

  // ── Helpers ────────────────────────────────────────────────
  function formatBytes(bytes: number | null): string {
    if (bytes == null || bytes === 0) return '\u2014';
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
    if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  }

  let scoringRemaining = $state(false);

  async function scoreRemaining() {
    if (scoringRemaining) return;
    scoringRemaining = true;
    try {
      const data = await api.post<{ queued: number }>('/api/admin/sdk/score-remaining');
      message = data.queued > 0
        ? `Queued ${data.queued} package(s) for scoring.`
        : 'All packages are already scored.';
    } catch (e: any) {
      message = e.message ?? 'Failed to queue packages.';
    } finally {
      scoringRemaining = false;
    }
  }

  // ── Rescan All ────────────────────────────────────────────
  let rescanDialogOpen = $state(false);
  let rescanScope = $state<'latest' | 'all'>('latest');
  let rescanning = $state(false);

  function openRescanDialog() {
    rescanScope = 'latest';
    rescanDialogOpen = true;
  }

  $effect(() => {
    if (!rescanDialogOpen) return;
    let confirmOpen = false;
    const unsub = confirmState.subscribe((s) => { confirmOpen = !!s?.open; });
    function onKeydown(e: KeyboardEvent) {
      // Skip if a confirmDialog is layered on top — let it handle ESC.
      if (e.key === 'Escape' && !confirmOpen && !rescanning) {
        rescanDialogOpen = false;
      }
    }
    window.addEventListener('keydown', onKeydown);
    return () => {
      window.removeEventListener('keydown', onKeydown);
      unsub();
    };
  });

  async function confirmRescan() {
    if (rescanning) return;
    const label = rescanScope === 'latest' ? 'latest version of every package' : 'every version of every package';
    const ok = await confirmDialog({
      title: `Rescan the ${label}?`,
      description: 'Existing scores will be replaced.',
      confirmLabel: 'Rescan',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    rescanning = true;
    try {
      const data = await api.post<{ queued: number }>(
        '/api/admin/sdk/rescan-all',
        { scope: rescanScope },
      );
      message = data.queued > 0
        ? `Queued ${data.queued} version(s) for rescan.`
        : 'Nothing to rescan.';
      rescanDialogOpen = false;
    } catch (e: any) {
      message = e.message ?? 'Failed to queue rescan.';
    } finally {
      rescanning = false;
    }
  }

  // ── Cancel running scoring jobs ───────────────────────────
  let cancelling = $state<Record<string, boolean>>({});
  let cancellingAll = $state(false);

  function jobKey(j: InFlightJob): string {
    return `${j.packageName}@${j.version}`;
  }

  /// Pull fresh settings immediately after a kill so the operator sees
  /// the count drop without waiting on the 5s poll. Runs after the
  /// backend's tree-kill has already been awaited, so the in-flight
  /// list should already reflect post-cancel state.
  async function refreshSettings() {
    try {
      const data = await api.get<Settings>('/api/admin/sdk/settings');
      if (settings) {
        settings = {
          ...settings,
          workers: data.workers,
          coverage: data.coverage,
          discovery: data.discovery,
        };
      }
    } catch {
      /* ignore */
    }
  }

  async function cancelJob(job: InFlightJob) {
    const key = jobKey(job);
    if (cancelling[key]) return;
    const ok = await confirmDialog({
      title: `Kill ${job.packageName} ${job.version}?`,
      description: `The subprocess (pid ${job.pid}) will be killed and the job will be recorded as failed. The next queued job will start automatically.`,
      confirmLabel: 'Kill',
      confirmVariant: 'destructive',
    });
    if (!ok) return;
    cancelling = { ...cancelling, [key]: true };
    try {
      const data = await api.post<{ cancelled: number }>(
        '/api/admin/sdk/cancel-in-flight',
        { packageName: job.packageName, version: job.version },
      );
      message = data.cancelled > 0
        ? `Killed ${job.packageName} ${job.version}.`
        : `${job.packageName} ${job.version} was no longer running.`;
    } catch (e: any) {
      message = e.message ?? 'Failed to cancel job.';
    } finally {
      cancelling = { ...cancelling, [key]: false };
      await refreshSettings();
    }
  }

  async function cancelAllJobs() {
    if (cancellingAll) return;
    const count = settings?.workers.inFlightJobs?.length ?? 0;
    if (count === 0) return;
    const ok = await confirmDialog({
      title: `Kill all ${count} running scoring job${count === 1 ? '' : 's'}?`,
      description: 'Each subprocess will be killed and recorded as failed. The dispatcher will pick up the next queued jobs automatically.',
      confirmLabel: 'Kill all',
      confirmVariant: 'destructive',
    });
    if (!ok) return;
    cancellingAll = true;
    try {
      const data = await api.post<{ cancelled: number }>(
        '/api/admin/sdk/cancel-in-flight',
      );
      message = data.cancelled > 0
        ? `Killed ${data.cancelled} running job${data.cancelled === 1 ? '' : 's'}.`
        : 'No running jobs to kill.';
    } catch (e: any) {
      message = e.message ?? 'Failed to cancel jobs.';
    } finally {
      cancellingAll = false;
      await refreshSettings();
    }
  }

  async function copyLogs() {
    if (scoringLogs.length === 0) return;
    try {
      await navigator.clipboard.writeText(scoringLogs.join('\n'));
      message = 'Logs copied to clipboard.';
    } catch {
      message = 'Failed to copy logs.';
    }
  }

  async function clearLogs() {
    try {
      await api.delete('/api/admin/sdk/scoring-logs');
      scoringLogs = [];
      message = 'Logs cleared.';
    } catch {
      message = 'Failed to clear logs.';
    }
  }

  function statusLabel(status: string): string {
    switch (status) {
      case 'cloning': return 'cloning';
      case 'settingUp': return 'setting up';
      case 'ready': return 'ready';
      case 'failed': return 'failed';
      default: return status;
    }
  }

  function phaseLabel(status: string): string {
    switch (status) {
      case 'cloning': return 'Cloning repository...';
      case 'settingUp': return 'Setting up SDK...';
      default: return status;
    }
  }
</script>

<div class="sdk-settings">
  <h2>Scoring</h2>
  <p class="subtitle">Package analysis powered by pana. Install a Flutter SDK to enable scoring.</p>

  {#if loading}
    <p class="loading">Loading...</p>
  {:else if error}
    <div class="error-card">{error}</div>
  {:else if settings}

    {#if message}
      <div class="message-card">{message}</div>
    {/if}

    <!-- Scoring Toggle -->
    <div class="info-card">
      <div class="toggle-row">
        <div>
          <h3>Package scoring</h3>
          <p>Automatically analyze published packages with pana and assign quality scores.</p>
        </div>
        <label class="toggle">
          <input type="checkbox" checked={settings.scoringEnabled} onchange={toggleScoring} />
          <span class="toggle-slider"></span>
        </label>
      </div>
    </div>

    <!-- Scoring Stats -->
    {#if settings.scoringEnabled}
      <div class="info-card">
        <div class="stats-header">
          <h3>Scoring Stats</h3>
          <div class="stats-actions">
            <button
              class="action-btn"
              disabled={scoringRemaining || settings.coverage.scoredPackages === settings.coverage.totalPackages}
              onclick={scoreRemaining}
            >{scoringRemaining ? 'Queuing...' : 'Process Remaining'}</button>
            <button
              class="action-btn"
              disabled={rescanning}
              onclick={openRescanDialog}
            >{rescanning ? 'Queuing...' : 'Rescan All'}</button>
          </div>
        </div>
        <div class="stats-grid">
          <div class="stat">
            <span class="stat-value">{settings.coverage.scoredPackages}/{settings.coverage.totalPackages}</span>
            <span class="stat-label">packages scored</span>
          </div>
          <div class="stat">
            <span class="stat-value">{settings.workers.active}</span>
            <span class="stat-label">active jobs</span>
          </div>
          <div class="stat">
            <span class="stat-value">{settings.workers.queued}</span>
            <span class="stat-label">queued</span>
          </div>
          <div class="stat">
            <span class="stat-value">{settings.workers.total}</span>
            <span class="stat-label">workers</span>
          </div>
        </div>

        {#if (settings.workers.inFlightJobs?.length ?? 0) > 0}
          <div class="in-flight-section">
            <div class="in-flight-header">
              <h4>Running jobs</h4>
              <button
                class="action-btn danger"
                disabled={cancellingAll}
                onclick={cancelAllJobs}
              >{cancellingAll ? 'Killing...' : 'Kill all'}</button>
            </div>
            <ul class="in-flight-list">
              {#each settings.workers.inFlightJobs ?? [] as job (jobKey(job))}
                <li class="in-flight-row">
                  <div class="in-flight-meta">
                    <span class="in-flight-name">{job.packageName} <span class="in-flight-version">{job.version}</span></span>
                    <span class="in-flight-pid">pid {job.pid}</span>
                  </div>
                  <button
                    class="action-btn danger sm"
                    disabled={cancelling[jobKey(job)]}
                    onclick={() => cancelJob(job)}
                  >{cancelling[jobKey(job)] ? 'Killing...' : 'Kill'}</button>
                </li>
              {/each}
            </ul>
          </div>
        {/if}
      </div>
    {/if}

    <!-- Scoring Logs -->
    <div class="info-card">
      <div class="scoring-logs-header">
        <button class="scoring-logs-toggle" onclick={() => scoringLogsExpanded = !scoringLogsExpanded}>
          <svg class="chevron" class:expanded={scoringLogsExpanded} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>
          <h3>Scoring Logs</h3>
          {#if scoringLogsExpanded}
            <span class="log-count">last 300 lines</span>
          {/if}
        </button>
        {#if scoringLogsExpanded && scoringLogs.length > 0}
          <div class="scoring-logs-actions">
            <button class="icon-btn" title="Copy logs" onclick={copyLogs}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>
            </button>
            <button class="icon-btn" title="Clear logs" onclick={clearLogs}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/></svg>
            </button>
          </div>
        {/if}
      </div>
      {#if scoringLogsExpanded}
        <div class="scoring-logs-container">
          <pre class="scoring-logs-output" bind:this={scoringLogsEl} onscroll={(e) => handleLogScroll('_scoring', e.currentTarget)}>{#if scoringLogs.length > 0}{scoringLogs.join('\n')}{:else}No scoring logs yet.{/if}</pre>
          {#if userScrolledAway['_scoring']}
            <button class="jump-bottom-btn" onclick={() => jumpToBottom('_scoring')}>Jump to bottom</button>
          {/if}
        </div>
      {/if}
    </div>

    <!-- Discovery error (from the most recent startup or manual scan) -->
    {#if settings.discovery?.error}
      <div class="discovery-error">
        <div class="discovery-head">
          <strong>SDK discovery failed</strong>
          {#if settings.discovery.at}
            <span class="when">at {new Date(settings.discovery.at).toLocaleString()}</span>
          {/if}
        </div>
        <pre class="discovery-body">{settings.discovery.error}</pre>
        <p class="discovery-hint">The server couldn't reconcile <code>/data/sdks</code> against the database. Click "Scan Disk" to retry.</p>
      </div>
    {/if}

    <!-- Installed SDKs -->
    <div class="info-card">
      <div class="installed-header">
        <h3>Installed SDKs</h3>
        <button class="action-btn" disabled={scanning} onclick={scanDisk} title="Rediscover SDK directories present in /data/sdks but not tracked by the server">
          {scanning ? 'Scanning…' : 'Scan Disk'}
        </button>
      </div>
      {#if installs.length === 0}
        <p class="empty">No SDKs installed. Install one below to enable scoring.</p>
      {:else}
        <div class="install-list">
          {#each installs as install}
            <div class="install-row">
              <div class="install-info">
                <div class="install-header">
                  <span class="install-version">Flutter {install.version}</span>
                  <span class="install-channel">{install.channel}</span>
                  {#if install.isDefault}
                    <span class="badge default">default</span>
                  {/if}
                  <span class="badge {install.status}">{statusLabel(install.status)}</span>
                </div>
                {#if install.dartVersion}
                  <span class="install-detail">Dart {install.dartVersion}</span>
                {/if}
                {#if install.status === 'ready' && install.sizeBytes}
                  <span class="install-detail">{formatBytes(install.sizeBytes)}</span>
                {/if}
                {#if install.status === 'failed' && install.errorMessage}
                  <span class="install-error">{install.errorMessage}</span>
                {/if}
                {#if install.status === 'cloning' || install.status === 'settingUp'}
                  <div class="progress-indicator">
                    <span class="spinner"></span>
                    <span class="install-detail">{phaseLabel(install.status)}</span>
                  </div>
                {/if}
                <!-- Collapsible logs view -->
                {#if progress[install.id]?.logs?.length || install.status === 'cloning' || install.status === 'settingUp'}
                  {@const logs = progress[install.id]?.logs ?? []}
                  <button class="logs-toggle" onclick={() => toggleLogs(install.id)}>
                    <svg class="chevron" class:expanded={expandedLogs[install.id]} width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>
                    Logs{#if logs.length > 0}&nbsp;<span class="log-count">({logs.length})</span>{/if}
                  </button>
                  {#if expandedLogs[install.id]}
                    <div class="logs-container">
                      <pre class="logs-output" bind:this={logElements[install.id]} onscroll={(e) => handleLogScroll(install.id, e.currentTarget)}>{#if logs.length > 0}{logs.join('\n')}{:else}Waiting for output...{/if}</pre>
                      {#if userScrolledAway[install.id]}
                        <button class="jump-bottom-btn" onclick={() => jumpToBottom(install.id)}>Jump to bottom</button>
                      {/if}
                    </div>
                  {/if}
                {/if}
              </div>
              <div class="install-actions">
                {#if install.status === 'ready' && !install.isDefault}
                  <button class="action-btn" onclick={() => setDefault(install.id)}>Set default</button>
                {/if}
                {#if install.status === 'ready' || install.status === 'failed'}
                  <button class="action-btn" onclick={() => rebuildInstall(install.id)}>Rebuild</button>
                  <button class="action-btn danger" onclick={() => deleteInstall(install.id, install.version)}>Delete</button>
                {/if}
              </div>
            </div>
          {/each}
        </div>
      {/if}
    </div>

    <!-- Install New SDK -->
    <div class="info-card">
      <h3>Install Flutter SDK</h3>
      <p>Select a channel and version to install via git clone. Platform: <code>{settings.platform}</code>.
        Available disk space: <strong>{formatBytes(settings.availableDiskSpace)}</strong>.</p>

      <div class="download-form">
        <div class="form-row">
          <label class="form-label" for="sdk-channel">Channel</label>
          <select id="sdk-channel" class="form-select" bind:value={selectedChannel}>
            <option value="stable">Stable</option>
            <option value="beta">Beta</option>
            <option value="dev">Dev</option>
          </select>
        </div>
        <div class="form-row">
          <label class="form-label" for="sdk-version">Version</label>
          <select id="sdk-version" class="form-select" bind:value={selectedRelease} disabled={releasesLoading || releases.length === 0}>
            {#if releasesLoading}
              <option>Loading...</option>
            {:else if releases.length === 0}
              <option>No versions available</option>
            {:else}
              <option value={null}>Select a version...</option>
              {#each releases.slice(0, 25) as release}
                <option value={release}>
                  {release.version} (Dart {release.dartVersion})
                </option>
              {/each}
            {/if}
          </select>
        </div>
        <button
          class="download-btn"
          disabled={!selectedRelease || installPending}
          onclick={startInstall}
        >
          {installPending ? 'Starting...' : 'Install'}
        </button>
      </div>
    </div>
  {/if}

  {#if rescanDialogOpen}
    <div class="modal-backdrop" onclick={(e) => { if (e.target === e.currentTarget && !rescanning) rescanDialogOpen = false; }} role="presentation">
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="rescan-title" tabindex="-1">
        <h3 id="rescan-title">Rescan all packages</h3>
        <p>Re-queue packages for pana analysis. Existing scores will be replaced with fresh results.</p>
        <div class="radio-group">
          <label class="radio-row">
            <input type="radio" name="rescan-scope" value="latest" bind:group={rescanScope} />
            <div>
              <span class="radio-label">Latest versions only</span>
              <span class="radio-hint">One score per package. Faster.</span>
            </div>
          </label>
          <label class="radio-row">
            <input type="radio" name="rescan-scope" value="all" bind:group={rescanScope} />
            <div>
              <span class="radio-label">All versions</span>
              <span class="radio-hint">Every published version of every package. Can take a long time.</span>
            </div>
          </label>
        </div>
        <div class="modal-actions">
          <button class="action-btn" disabled={rescanning} onclick={() => rescanDialogOpen = false}>Cancel</button>
          <button class="action-btn primary" disabled={rescanning} onclick={confirmRescan}>
            {rescanning ? 'Queuing...' : 'Rescan'}
          </button>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  .sdk-settings { font-size: 14px; }

  h2 { font-size: 20px; font-weight: 600; margin: 0 0 6px; color: var(--foreground); }
  .subtitle { margin: 0 0 24px; color: var(--muted-foreground); line-height: 1.5; }

  .loading { color: var(--muted-foreground); font-style: italic; }
  .error-card {
    padding: 12px 16px;
    background: color-mix(in srgb, var(--destructive) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--destructive) 25%, transparent);
    border-radius: 8px;
    color: var(--destructive);
    margin-bottom: 16px;
  }
  .message-card {
    padding: 10px 14px;
    background: var(--pub-tag-background);
    border: 1px solid var(--border);
    border-radius: 6px;
    margin-bottom: 16px;
    font-size: 13px;
    color: var(--pub-default-text-color);
  }

  .info-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 20px;
    margin-bottom: 16px;
  }
  .info-card h3 { font-size: 15px; font-weight: 600; margin: 0 0 12px; color: var(--foreground); }
  .info-card p { margin: 0 0 12px; color: var(--muted-foreground); line-height: 1.5; }

  /* ── Stats ────────────────────────────────────────── */
  .stats-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
  .stats-header h3 { margin: 0; }
  .stats-actions { display: flex; gap: 6px; }
  .stats-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
  @media (min-width: 640px) {
    .stats-grid { grid-template-columns: repeat(4, 1fr); }
  }
  .stat { text-align: center; padding: 12px 8px; background: var(--muted); border-radius: 8px; }
  .stat-value { display: block; font-size: 20px; font-weight: 700; color: var(--foreground); }
  .stat-label { display: block; font-size: 11px; color: var(--muted-foreground); text-transform: uppercase; letter-spacing: 0.03em; margin-top: 2px; }

  .toggle-row { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 12px 20px; }
  .toggle-row h3 { margin: 0 0 4px; }
  .toggle-row p { margin: 0; }
  .toggle { position: relative; display: inline-block; width: 44px; height: 24px; flex-shrink: 0; }
  .toggle input[type="checkbox"] {
    opacity: 0; width: 0; height: 0; margin: 0; padding: 0;
    border: 0; background: transparent; position: absolute;
  }
  .toggle input[type="checkbox"]:checked { background: transparent; border: 0; }
  .toggle input[type="checkbox"]:checked::after { content: none; }
  .toggle-slider {
    position: absolute; inset: 0; cursor: pointer;
    background: var(--muted); border-radius: 24px;
    transition: background 0.2s;
  }
  .toggle-slider::before {
    content: ''; position: absolute;
    width: 18px; height: 18px; left: 3px; bottom: 3px;
    background: white; border-radius: 50%;
    transition: transform 0.2s;
  }
  .toggle input:checked + .toggle-slider { background: var(--success, #4caf50); }
  .toggle input:checked + .toggle-slider::before { transform: translateX(20px); }

  .installed-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 12px;
  }
  .installed-header h3 { margin: 0; }

  .discovery-error {
    padding: 14px 16px;
    background: color-mix(in srgb, var(--destructive) 8%, transparent);
    border: 1px solid color-mix(in srgb, var(--destructive) 30%, transparent);
    border-radius: 10px;
    margin-bottom: 16px;
  }
  .discovery-head {
    display: flex;
    align-items: baseline;
    gap: 10px;
    margin-bottom: 8px;
  }
  .discovery-head strong {
    color: var(--destructive);
    font-size: 14px;
  }
  .discovery-head .when {
    font-size: 12px;
    color: var(--muted-foreground);
  }
  .discovery-body {
    margin: 0;
    padding: 10px 12px;
    background: color-mix(in srgb, var(--destructive) 6%, var(--muted));
    border-radius: 6px;
    font-family: var(--pub-code-font-family);
    font-size: 12px;
    line-height: 1.5;
    color: var(--foreground);
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-word;
  }
  .discovery-hint {
    margin: 8px 0 0;
    color: var(--muted-foreground);
    font-size: 12px;
  }

  .empty { color: var(--muted-foreground); font-style: italic; margin: 0; }
  .install-list { display: flex; flex-direction: column; }
  .install-row {
    display: flex; justify-content: space-between; align-items: flex-start;
    padding: 14px 0; border-bottom: 1px solid var(--border); gap: 16px;
  }
  .install-row:last-child { border-bottom: none; }
  .install-info { flex: 1; min-width: 0; }
  .install-header { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
  .install-version { font-weight: 600; font-size: 14px; color: var(--foreground); }
  .install-channel { font-size: 12px; color: var(--muted-foreground); }
  .install-detail { display: block; font-size: 12px; color: var(--muted-foreground); margin-top: 4px; }
  .install-error { display: block; font-size: 12px; color: var(--destructive); margin-top: 4px; }
  .install-actions { display: flex; gap: 6px; flex-shrink: 0; padding-top: 2px; }

  .badge {
    font-size: 11px; font-weight: 600; padding: 2px 8px;
    border-radius: 4px;
  }
  .badge.default { background: color-mix(in srgb, var(--success, #4caf50) 15%, transparent); color: var(--success, #4caf50); }
  .badge.ready { background: color-mix(in srgb, var(--success, #4caf50) 10%, transparent); color: var(--success, #4caf50); }
  .badge.cloning, .badge.settingUp { background: color-mix(in srgb, var(--pub-link-text-color) 15%, transparent); color: var(--pub-link-text-color); }
  .badge.failed { background: color-mix(in srgb, var(--pub-error-color) 15%, transparent); color: var(--pub-error-color); }

  .action-btn {
    padding: 4px 12px; border: 1px solid var(--border); border-radius: 6px;
    background: transparent; font-size: 12px; font-weight: 500;
    cursor: pointer; font-family: inherit; color: var(--foreground);
    transition: all 0.12s;
  }
  .action-btn:hover { background: var(--accent); }
  .action-btn.danger { color: var(--pub-error-color); border-color: var(--pub-error-color); }
  .action-btn.danger:hover { background: var(--pub-error-color); color: #fff; }
  .action-btn.sm { padding: 2px 8px; font-size: 11px; }

  /* ── In-flight scoring jobs ─────────────────────── */
  .in-flight-section {
    margin-top: 16px; padding-top: 16px;
    border-top: 1px solid var(--border);
  }
  .in-flight-header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 8px;
  }
  .in-flight-header h4 {
    margin: 0; font-size: 13px; font-weight: 600;
    color: var(--foreground);
  }
  .in-flight-list {
    list-style: none; margin: 0; padding: 0;
    display: flex; flex-direction: column; gap: 6px;
  }
  .in-flight-row {
    display: flex; align-items: center; justify-content: space-between;
    padding: 8px 10px;
    border: 1px solid var(--border); border-radius: 6px;
    background: var(--muted);
  }
  .in-flight-meta {
    display: flex; flex-direction: column; gap: 2px; min-width: 0;
  }
  .in-flight-name {
    font-size: 13px; font-weight: 500; color: var(--foreground);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .in-flight-version {
    color: var(--muted-foreground); font-weight: 400;
  }
  .in-flight-pid {
    font-size: 11px; color: var(--muted-foreground);
    font-family: var(--font-mono, ui-monospace, SFMono-Regular, monospace);
  }

  /* ── Progress indicator ──────────────────────────── */
  .progress-indicator {
    display: flex; align-items: center; gap: 8px; margin-top: 8px;
  }
  .spinner {
    width: 14px; height: 14px; border: 2px solid var(--border);
    border-top-color: var(--pub-link-text-color);
    border-radius: 50%; animation: spin 0.8s linear infinite;
    flex-shrink: 0;
  }
  .progress-indicator .install-detail { margin-top: 0; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ── Collapsible logs ────────────────────────────── */
  .logs-toggle {
    display: flex; align-items: center; gap: 4px;
    margin-top: 8px; padding: 0; border: none; background: none;
    font-size: 12px; font-weight: 500; font-family: inherit;
    color: var(--muted-foreground); cursor: pointer;
    transition: color 0.12s;
  }
  .logs-toggle:hover { color: var(--foreground); }
  .log-count { color: var(--muted-foreground); font-weight: 400; }
  .chevron {
    transition: transform 0.15s ease;
    flex-shrink: 0;
  }
  .chevron.expanded { transform: rotate(90deg); }

  .logs-container {
    margin-top: 8px;
    position: relative;
  }
  .logs-output {
    margin: 0; padding: 12px;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 6px;
    font-family: var(--pub-code-font-family);
    font-size: 11px; line-height: 1.6;
    color: var(--foreground);
    overflow-x: auto; white-space: pre-wrap;
    word-break: break-all;
    max-height: 320px; overflow-y: scroll;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }
  .logs-output::-webkit-scrollbar { width: 6px; height: 6px; }
  .logs-output::-webkit-scrollbar-track { background: transparent; }
  .logs-output::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  .logs-output::-webkit-scrollbar-thumb:hover { background: var(--muted-foreground); }

  .download-form { display: flex; flex-direction: column; gap: 12px; }
  .form-row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
  .form-label { font-size: 13px; font-weight: 500; color: var(--foreground); width: 70px; flex-shrink: 0; }
  .form-row .form-select { flex: 1 1 12rem; min-width: 0; }
  .form-select {
    flex: 1; padding: 8px 32px 8px 12px; border: 1px solid var(--border);
    border-radius: 6px; background: var(--background); color: var(--foreground);
    font-family: inherit; font-size: 13px;
    -webkit-appearance: none;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%23888' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 10px center;
  }
  .form-select:disabled { opacity: 0.5; }

  .download-btn {
    align-self: flex-start; padding: 8px 20px;
    border: 1px solid var(--primary); border-radius: 6px;
    background: var(--primary); color: var(--primary-foreground);
    font-size: 13px; font-weight: 600; cursor: pointer;
    font-family: inherit; transition: opacity 0.12s;
  }
  .download-btn:hover { opacity: 0.9; }
  .download-btn:disabled { opacity: 0.5; cursor: not-allowed; }

  code {
    font-size: 12px; font-family: var(--pub-code-font-family);
    background: var(--pub-code-background, var(--muted));
    padding: 1px 6px; border-radius: 4px;
  }

  /* ── Scoring logs ────────────────────────────────── */
  .scoring-logs-toggle {
    display: flex; align-items: center; gap: 6px;
    padding: 0; border: none; background: none;
    cursor: pointer; width: 100%;
  }
  .jump-bottom-btn {
    position: absolute; bottom: 10px; right: 10px;
    padding: 4px 12px; border: 1px solid var(--border);
    border-radius: 6px; background: var(--card);
    font-size: 11px; font-weight: 500; font-family: inherit;
    color: var(--foreground); cursor: pointer;
    box-shadow: 0 2px 8px rgba(0,0,0,0.25);
    transition: all 0.12s;
  }
  .jump-bottom-btn:hover { background: var(--accent); }

  .scoring-logs-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .scoring-logs-actions {
    display: flex;
    gap: 4px;
  }
  .icon-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: transparent;
    color: var(--muted-foreground);
    cursor: pointer;
    transition: all 0.12s;
  }
  .icon-btn:hover {
    background: var(--accent);
    color: var(--foreground);
  }
  .scoring-logs-toggle h3 { margin: 0; font-size: 15px; font-weight: 600; color: var(--foreground); }
  .scoring-logs-toggle .log-count { font-size: 12px; color: var(--muted-foreground); font-weight: 400; }
  .scoring-logs-container { margin-top: 12px; position: relative; }
  .scoring-logs-output {
    margin: 0; padding: 12px;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 6px;
    font-family: var(--pub-code-font-family);
    font-size: 11px; line-height: 1.6;
    color: var(--foreground);
    overflow-x: auto; white-space: pre-wrap;
    word-break: break-all;
    max-height: 400px; overflow-y: scroll;
    scrollbar-width: thin;
    scrollbar-color: var(--border) transparent;
  }
  .scoring-logs-output::-webkit-scrollbar { width: 6px; height: 6px; }
  .scoring-logs-output::-webkit-scrollbar-track { background: transparent; }
  .scoring-logs-output::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  .scoring-logs-output::-webkit-scrollbar-thumb:hover { background: var(--muted-foreground); }

  /* ── Modal ───────────────────────────────────────── */
  .modal-backdrop {
    position: fixed; inset: 0;
    background: rgba(0, 0, 0, 0.5);
    display: flex; align-items: center; justify-content: center;
    z-index: 100; padding: 16px;
  }
  .modal {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 24px;
    width: 100%; max-width: 460px;
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
  }
  .modal h3 { margin: 0 0 6px; font-size: 16px; font-weight: 600; color: var(--foreground); }
  .modal p { margin: 0 0 16px; color: var(--muted-foreground); line-height: 1.5; font-size: 13px; }
  .radio-group { display: flex; flex-direction: column; gap: 8px; margin-bottom: 20px; }
  .radio-row {
    display: flex; gap: 10px; align-items: flex-start;
    padding: 12px; border: 1px solid var(--border);
    border-radius: 8px; cursor: pointer;
    transition: background 0.12s, border-color 0.12s;
  }
  .radio-row:hover { background: var(--accent); }
  .radio-row:has(input:checked) { border-color: var(--primary); background: color-mix(in srgb, var(--primary) 6%, transparent); }
  .radio-row input { margin-top: 2px; flex-shrink: 0; }
  .radio-label { display: block; font-weight: 500; font-size: 13px; color: var(--foreground); }
  .radio-hint { display: block; font-size: 12px; color: var(--muted-foreground); margin-top: 2px; }
  .modal-actions { display: flex; justify-content: flex-end; gap: 8px; }
  .action-btn.primary {
    background: var(--primary);
    border-color: var(--primary);
    color: var(--primary-foreground);
  }
  .action-btn.primary:hover { opacity: 0.9; background: var(--primary); }
</style>
