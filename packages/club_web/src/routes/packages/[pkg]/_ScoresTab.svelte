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

  // Render the full report as portable markdown so a maintainer can paste
  // it into a GitHub issue, a Slack thread, or an LLM context window
  // without losing the section/criterion structure. Mirrors the parser
  // used by ScoreSection so the criteria break out the same way they
  // render — collapsing them back into the raw `### […]` blob would
  // hide the failed/partial reasons under one giant code fence.
  function buildReportMarkdown(r: ScoringReport): string {
    const lines: string[] = [];
    lines.push(`# Pana scoring: ${packageName} ${version}`);
    lines.push("");
    const total = `**${r.grantedPoints ?? 0} / ${r.maxPoints ?? 0} points**`;
    const when = r.analyzedAt
      ? ` • analyzed ${new Date(r.analyzedAt).toISOString()}`
      : "";
    lines.push(`${total}${when}`);
    const toolParts: string[] = [];
    if (r.panaVersion) toolParts.push(`Pana ${r.panaVersion}`);
    if (r.dartVersion) toolParts.push(`Dart ${r.dartVersion}`);
    if (r.flutterVersion) toolParts.push(`Flutter ${r.flutterVersion}`);
    if (toolParts.length > 0) lines.push(toolParts.join(", "));
    lines.push("");

    for (const section of r.sections ?? []) {
      lines.push(
        `## ${section.title} — ${section.grantedPoints}/${section.maxPoints}`,
      );
      lines.push("");
      const criteria = parseCriteriaForCopy(section.summary);
      if (criteria.length > 0) {
        for (const c of criteria) {
          lines.push(
            `- ${c.glyph} ${c.points}/${c.maxPoints} — ${c.title}`,
          );
          if (c.body) {
            for (const bodyLine of c.body.split("\n")) {
              lines.push(`  ${bodyLine}`);
            }
          }
        }
      } else if (section.summary?.trim()) {
        // Sections without the standard `### [*|~|x]` shape (e.g.
        // a single-paragraph rationale) get pasted verbatim.
        lines.push(section.summary.trim());
      }
      lines.push("");
    }

    return lines.join("\n").replace(/\n{3,}/g, "\n\n").trimEnd() + "\n";
  }

  // Parse pana's `### [mark] N/M points: title` headings into rows so
  // the copy output can list each criterion on its own line. Body text
  // between headings stays attached to the preceding criterion. Inline
  // markdown (backticks, **bold**) is preserved as-is — the consumer
  // is another markdown-aware tool.
  function parseCriteriaForCopy(md: string): {
    glyph: string;
    points: number;
    maxPoints: number;
    title: string;
    body: string;
  }[] {
    const headingRe = /^### \[([*~x])\] (\d+)\/(\d+) points: (.+)$/;
    const out: ReturnType<typeof parseCriteriaForCopy> = [];
    let cur:
      | (typeof out)[number]
      | null = null;
    for (const line of md.split("\n")) {
      const m = line.match(headingRe);
      if (m) {
        if (cur) out.push({ ...cur, body: cur.body.trim() });
        const mark = m[1];
        cur = {
          glyph: mark === "*" ? "✓" : mark === "~" ? "~" : "✕",
          points: parseInt(m[2], 10),
          maxPoints: parseInt(m[3], 10),
          title: m[4],
          body: "",
        };
      } else if (cur) {
        cur.body += line + "\n";
      }
    }
    if (cur) out.push({ ...cur, body: cur.body.trim() });
    return out;
  }

  let copied = $state(false);
  async function copyReport() {
    if (!report || report.status !== "completed") return;
    try {
      await navigator.clipboard.writeText(buildReportMarkdown(report));
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch {
      // Clipboard API unavailable on non-secure origins; silently no-op,
      // mirroring the pattern used by copyReadme in _PackageView.
    }
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
    <div class="summary-row">
      <p class="summary-line">
        We analyzed this package {timeAgo(report?.analyzedAt)}, and awarded it
        <strong>{report?.grantedPoints}</strong> pub points (of a possible {report?.maxPoints}):
      </p>
      <button
        class="copy-report-btn"
        type="button"
        onclick={copyReport}
        title={copied ? "Copied" : "Copy report as markdown"}
        aria-label={copied ? "Report copied" : "Copy report as markdown"}
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
          >
            <rect x="9" y="9" width="13" height="13" rx="2" />
            <path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1" />
          </svg>
        {/if}
      </button>
    </div>

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

  .summary-row {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 16px;
    padding: 12px 0 20px;
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .summary-row .summary-line {
    padding: 0;
    border-bottom: none;
    flex: 1;
  }

  .summary-line {
    padding: 12px 0 20px;
    font-size: 15px;
    color: var(--pub-default-text-color);
    line-height: 1.5;
    border-bottom: 1px solid var(--pub-divider-color);
  }

  .copy-report-btn {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    margin-top: 2px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--pub-muted-text-color);
    cursor: pointer;
    transition:
      color 0.15s,
      border-color 0.15s;
  }
  .copy-report-btn:hover {
    color: var(--foreground);
    border-color: var(--pub-muted-text-color);
  }
  .copy-report-btn:focus-visible {
    outline: 2px solid var(--pub-default-text-color);
    outline-offset: 2px;
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
