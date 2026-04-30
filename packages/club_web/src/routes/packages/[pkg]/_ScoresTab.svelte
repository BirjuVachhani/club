<script lang="ts">
  import ScoreSection from "$lib/components/ScoreSection.svelte";
  import WeeklyDownloadsChart from "$lib/components/WeeklyDownloadsChart.svelte";
  import { api, ApiError, apiErrorMessage } from "$lib/api/client";

  interface Props {
    packageName: string;
    version: string;
  }

  let { packageName, version }: Props = $props();

  interface ScoringReport {
    status:
      | "completed"
      | "pending"
      | "running"
      | "disabled"
      | "failed"
      | "not_analyzed";
    grantedPoints?: number;
    maxPoints?: number;
    sections?: {
      id: string;
      title: string;
      grantedPoints: number;
      maxPoints: number;
      status: string;
      summary: string;
    }[];
    panaVersion?: string;
    dartVersion?: string;
    flutterVersion?: string;
    analyzedAt?: string;
    errorMessage?: string;
  }

  interface DownloadWeek {
    weekStart: string;
    weekLabel: string;
    total: number;
    byVersion: Record<string, number>;
  }

  interface DownloadHistory {
    packageName: string;
    total30Days: number;
    weeks: DownloadWeek[];
  }

  let report = $state<ScoringReport | null>(null);
  let loadError = $state<{ status: number | null; message: string } | null>(
    null,
  );
  let loading = $state(true);
  let expandedSection = $state<string | null>(null);
  let downloadHistory = $state<DownloadHistory | null>(null);

  $effect(() => {
    // Re-fetch when package or version changes.
    void packageName;
    void version;
    loadReport();
    loadDownloads();
  });

  async function loadDownloads() {
    downloadHistory = null;
    try {
      downloadHistory = await api.get<DownloadHistory>(
        `/api/packages/${packageName}/downloads`,
      );
    } catch {
      downloadHistory = null;
    }
  }

  async function loadReport() {
    loading = true;
    report = null;
    loadError = null;
    expandedSection = null;
    try {
      const v = encodeURIComponent(version);
      report = await api.get<ScoringReport>(
        `/api/packages/${packageName}/versions/${v}/scoring-report`,
      );
    } catch (err) {
      // Don't fall back to `{status: "not_analyzed"}` here — that conflates
      // "server says no score row exists" with "the request itself failed",
      // which previously masked a real bug (versions with `+` in them hit
      // 404s due to an unrelated router issue, yet the UI silently read
      // "not analyzed"). Keep the two states distinct.
      console.error("Failed to load scoring report:", err);
      loadError = {
        status: err instanceof ApiError ? err.status : null,
        message: apiErrorMessage(err, "Failed to load scoring report."),
      };
    } finally {
      loading = false;
    }
  }

  function timeAgo(dateStr: string | null | undefined): string {
    if (!dateStr) return "";
    const diff = Date.now() - new Date(dateStr).getTime();
    const days = Math.floor(diff / 86400000);
    if (days === 0) return "today";
    if (days === 1) return "yesterday";
    if (days < 30) return `${days} days ago`;
    if (days < 365) return `${Math.floor(days / 30)} months ago`;
    return `${Math.floor(days / 365)} years ago`;
  }

  function toggleSection(id: string) {
    expandedSection = expandedSection === id ? null : id;
  }
</script>

<div class="scores-tab">
  {#if loading}
    <p class="empty-tab">Loading...</p>
  {:else if loadError}
    <div class="status-card error">
      <p>
        Couldn't load the scoring report{loadError.status
          ? ` (HTTP ${loadError.status})`
          : ""}.
      </p>
      <p class="hint">{loadError.message}</p>
      <button type="button" class="retry-btn" onclick={loadReport}>
        Retry
      </button>
    </div>
  {:else if report?.status === "disabled"}
    <div class="status-card muted">
      <p>Package scoring is not configured on this server.</p>
      <p class="hint">
        The server administrator needs to set the <code>DART_SDK</code> environment
        variable to enable pana analysis.
      </p>
    </div>
  {:else if report?.status === "not_analyzed"}
    <div class="status-card muted">
      <p>This version has not been analyzed yet.</p>
    </div>
  {:else if report?.status === "pending"}
    <div class="status-card info">
      <p>Analysis is queued. Check back shortly.</p>
    </div>
  {:else if report?.status === "running"}
    <div class="status-card info">
      <p>Analysis is in progress. Check back shortly.</p>
    </div>
  {:else if report?.status === "failed"}
    <div class="status-card error">
      <p>Analysis failed.</p>
      {#if report?.errorMessage}
        <details>
          <summary>Error details</summary>
          <pre class="error-log">{report.errorMessage}</pre>
        </details>
      {/if}
    </div>
  {:else if report?.status === "completed"}
    <p class="summary-line">
      We analyzed this package {timeAgo(report?.analyzedAt)}, and awarded it
      <strong>{report?.grantedPoints}</strong> pub points (of a possible {report?.maxPoints}):
    </p>

    <div class="sections">
      {#each report?.sections ?? [] as section}
        <ScoreSection
          {section}
          expanded={expandedSection === section.id}
          ontoggle={() => toggleSection(section.id)}
        />
      {/each}
    </div>

    <p class="footer">
      Analyzed with Pana
      {#if report?.panaVersion}<code>{report.panaVersion}</code
        >{/if}{#if report?.flutterVersion}, Flutter <code
          >{report.flutterVersion}</code
        >{/if}{#if report?.dartVersion}, Dart <code>{report.dartVersion}</code
        >{/if}.
    </p>
  {/if}

  {#if downloadHistory?.weeks?.length}
    <WeeklyDownloadsChart weeks={downloadHistory.weeks} />
  {/if}
</div>

<style>
  .scores-tab {
    font-size: 14px;
  }

  .empty-tab {
    padding: 40px 0;
    text-align: center;
    color: var(--pub-muted-text-color);
    font-style: italic;
  }

  .status-card {
    padding: 16px 20px;
    border-radius: 8px;
    margin-bottom: 16px;
    font-size: 14px;
    line-height: 1.5;
  }
  .status-card p {
    margin: 0 0 6px;
  }
  .status-card p:last-child {
    margin-bottom: 0;
  }
  .status-card.muted {
    background: var(--muted);
    border: 1px solid var(--border);
    color: var(--pub-muted-text-color);
  }
  .status-card.info {
    background: color-mix(in srgb, var(--pub-link-text-color) 8%, transparent);
    border: 1px solid
      color-mix(in srgb, var(--pub-link-text-color) 25%, transparent);
    color: var(--pub-default-text-color);
  }
  .status-card.error {
    background: color-mix(in srgb, var(--pub-error-color) 8%, transparent);
    border: 1px solid
      color-mix(in srgb, var(--pub-error-color) 25%, transparent);
    color: var(--pub-default-text-color);
  }

  .hint {
    font-size: 13px;
    color: var(--pub-muted-text-color);
  }
  .hint code {
    font-size: 12px;
    background: var(--pub-code-background);
    padding: 1px 6px;
    border-radius: 4px;
  }

  .error-log {
    margin: 8px 0 0;
    padding: 12px;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 12px;
    font-family: var(--pub-code-font-family);
    overflow-x: auto;
    max-height: 300px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }

  details summary {
    cursor: pointer;
    font-size: 13px;
    color: var(--pub-muted-text-color);
    margin-top: 4px;
  }

  .retry-btn {
    margin-top: 8px;
    padding: 6px 12px;
    font-size: 13px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--pub-default-background);
    color: var(--pub-default-text-color);
    cursor: pointer;
  }
  .retry-btn:hover {
    background: var(--muted);
  }

  .summary-line {
    padding: 12px 0 20px;
    font-size: 15px;
    color: var(--pub-default-text-color);
    line-height: 1.5;
    border-bottom: 1px solid var(--pub-divider-color);
  }

  .sections {
    margin-bottom: 20px;
  }

  .footer {
    padding: 16px 0;
    font-size: 13px;
    color: var(--pub-muted-text-color);
    border-top: 1px solid var(--pub-divider-color);
  }
  .footer code {
    font-size: 12px;
    background: var(--pub-code-background);
    padding: 1px 6px;
    border-radius: 4px;
    font-family: var(--pub-code-font-family);
  }
</style>
