<script lang="ts">
  /**
   * SVG line chart showing weekly download counts over time.
   * Supports total line + per-major-version breakdown lines.
   * No external dependencies — pure inline SVG.
   */

  interface DownloadWeek {
    weekStart: string;
    weekLabel: string;
    total: number;
    byVersion: Record<string, number>;
  }

  interface Props {
    weeks: DownloadWeek[];
  }

  let { weeks }: Props = $props();

  // Chart dimensions
  const W = 560;
  const H = 180;
  const PAD = { top: 12, right: 12, bottom: 28, left: 44 };
  const chartW = W - PAD.left - PAD.right;
  const chartH = H - PAD.top - PAD.bottom;

  // Aggregate by major version
  function majorOf(v: string): string {
    return 'v' + v.split('.')[0];
  }

  function toMajorBuckets(byVersion: Record<string, number>): Record<string, number> {
    const result: Record<string, number> = {};
    for (const [v, count] of Object.entries(byVersion)) {
      const maj = majorOf(v);
      result[maj] = (result[maj] ?? 0) + count;
    }
    return result;
  }

  // Collect all major versions across all weeks
  let allMajors = $derived.by(() => {
    const set = new Set<string>();
    for (const w of weeks) {
      for (const v of Object.keys(w.byVersion)) {
        set.add(majorOf(v));
      }
    }
    // Sort descending (newest major first)
    return [...set].sort((a, b) => {
      const na = parseInt(a.slice(1)) || 0;
      const nb = parseInt(b.slice(1)) || 0;
      return nb - na;
    });
  });

  // Color palette for version lines
  const COLORS = [
    '#4285f4', // blue
    '#ea4335', // red
    '#34a853', // green
    '#9334e6', // purple
    '#f9ab00', // amber
    '#00acc1', // cyan
    '#e91e63', // pink
    '#ff6d00', // orange
  ];

  function colorFor(index: number): string {
    return COLORS[index % COLORS.length];
  }

  // Computed chart data
  let maxVal = $derived(Math.max(...weeks.map((w) => w.total), 1));

  function x(i: number): number {
    if (weeks.length <= 1) return PAD.left + chartW / 2;
    return PAD.left + (i / (weeks.length - 1)) * chartW;
  }

  function y(val: number): number {
    return PAD.top + chartH - (val / maxVal) * chartH;
  }

  // Build polyline points for the total line
  let totalPoints = $derived(
    weeks.map((w, i) => `${x(i)},${y(w.total)}`).join(' '),
  );

  // Build polyline points for each major version
  let versionLines = $derived.by(() => {
    return allMajors.map((maj, idx) => {
      const points = weeks
        .map((w, i) => {
          const buckets = toMajorBuckets(w.byVersion);
          return `${x(i)},${y(buckets[maj] ?? 0)}`;
        })
        .join(' ');
      return { major: maj, points, color: colorFor(idx) };
    });
  });

  // Y-axis gridlines (4 lines)
  let gridLines = $derived.by(() => {
    const lines: { val: number; label: string; y: number }[] = [];
    const step = niceStep(maxVal, 4);
    for (let v = 0; v <= maxVal; v += step) {
      lines.push({ val: v, label: formatCount(v), y: y(v) });
    }
    // Always include max if step doesn't land on it
    if (lines.length > 0 && lines[lines.length - 1].val < maxVal) {
      lines.push({ val: maxVal, label: formatCount(maxVal), y: y(maxVal) });
    }
    return lines;
  });

  // X-axis labels — show ~6 evenly spaced labels
  let xLabels = $derived.by(() => {
    if (weeks.length === 0) return [];
    const labels: { label: string; x: number }[] = [];
    const step = Math.max(1, Math.floor(weeks.length / 6));
    for (let i = 0; i < weeks.length; i += step) {
      labels.push({ label: weeks[i].weekLabel, x: x(i) });
    }
    // Always include last
    const last = weeks.length - 1;
    if (labels.length === 0 || labels[labels.length - 1].x !== x(last)) {
      labels.push({ label: weeks[last].weekLabel, x: x(last) });
    }
    return labels;
  });

  // Area fill path for total downloads
  let totalAreaPath = $derived.by(() => {
    if (weeks.length === 0) return '';
    const baseline = PAD.top + chartH;
    let path = `M ${x(0)},${baseline}`;
    for (let i = 0; i < weeks.length; i++) {
      path += ` L ${x(i)},${y(weeks[i].total)}`;
    }
    path += ` L ${x(weeks.length - 1)},${baseline} Z`;
    return path;
  });

  let hasData = $derived(weeks.length > 0 && weeks.some((w) => w.total > 0));

  // Date range string
  let dateRange = $derived.by(() => {
    if (weeks.length === 0) return '';
    return `${weeks[0].weekStart}  \u2013  ${weeks[weeks.length - 1].weekStart}`;
  });

  function niceStep(max: number, targetLines: number): number {
    const rough = max / targetLines;
    const pow = Math.pow(10, Math.floor(Math.log10(rough)));
    const norm = rough / pow;
    let nice: number;
    if (norm <= 1) nice = 1;
    else if (norm <= 2) nice = 2;
    else if (norm <= 5) nice = 5;
    else nice = 10;
    return Math.max(1, nice * pow);
  }

  function formatCount(n: number): string {
    if (n >= 1_000_000) return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
    if (n >= 1_000) return (n / 1_000).toFixed(1).replace(/\.0$/, '') + 'k';
    return n.toString();
  }
</script>

<div class="downloads-chart">
  <h3>Weekly downloads</h3>

  {#if hasData}
    <svg viewBox="0 0 {W} {H}" class="chart-svg" preserveAspectRatio="xMidYMid meet"
         role="img" aria-labelledby="dl-chart-title">
      <title id="dl-chart-title">Weekly downloads chart showing download trends over time</title>
      <!-- Grid lines -->
      {#each gridLines as gl}
        <line
          x1={PAD.left}
          y1={gl.y}
          x2={W - PAD.right}
          y2={gl.y}
          class="grid-line"
        />
        <text x={PAD.left - 6} y={gl.y + 4} class="y-label">{gl.label}</text>
      {/each}

      <!-- Area fill for total -->
      <path d={totalAreaPath} class="area-fill" />

      <!-- Version breakdown lines -->
      {#each versionLines as vl}
        <polyline
          points={vl.points}
          fill="none"
          stroke={vl.color}
          stroke-width="1.5"
          stroke-linejoin="round"
          stroke-linecap="round"
          opacity="0.7"
        />
      {/each}

      <!-- Total line (on top) -->
      {#if weeks.length > 1}
        <polyline
          points={totalPoints}
          fill="none"
          class="total-line"
          stroke-width="2"
          stroke-linejoin="round"
          stroke-linecap="round"
        />
      {/if}

      <!-- Data point dots (visible for single point, hover targets otherwise) -->
      {#each weeks as w, i}
        <circle
          cx={x(i)}
          cy={y(w.total)}
          r={weeks.length === 1 ? 4 : 2.5}
          class="data-dot"
        />
      {/each}

      <!-- X-axis labels -->
      {#each xLabels as xl}
        <text x={xl.x} y={H - 4} class="x-label">{xl.label}</text>
      {/each}
    </svg>

    <!-- Legend -->
    {#if allMajors.length > 1}
      <div class="legend">
        {#each versionLines as vl}
          <span class="legend-item">
            <span class="legend-swatch" style="background:{vl.color}"></span>
            {vl.major}
          </span>
        {/each}
      </div>
    {/if}

    <p class="date-range">{dateRange}</p>
  {:else}
    <p class="empty">No download data yet.</p>
  {/if}
</div>

<style>
  .downloads-chart {
    margin-top: 24px;
    padding-top: 20px;
    border-top: 1px solid var(--pub-divider-color);
  }

  h3 {
    font-size: 16px;
    font-weight: 500;
    color: var(--pub-default-text-color);
    margin: 0 0 12px;
  }

  .chart-svg {
    display: block;
    width: 100%;
    max-width: 560px;
    height: auto;
  }

  .grid-line {
    stroke: var(--pub-divider-color);
    stroke-width: 0.5;
  }

  .y-label {
    font-size: 10px;
    fill: var(--pub-muted-text-color);
    text-anchor: end;
    dominant-baseline: middle;
  }

  .x-label {
    font-size: 10px;
    fill: var(--pub-muted-text-color);
    text-anchor: middle;
  }

  .area-fill {
    fill: var(--pub-link-text-color);
    opacity: 0.08;
  }

  .total-line {
    stroke: var(--pub-link-text-color);
  }

  .legend {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
    margin-top: 8px;
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }

  .legend-item {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .legend-swatch {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 2px;
  }

  .date-range {
    margin: 8px 0 0;
    font-size: 12px;
    color: var(--pub-muted-text-color);
  }

  .data-dot {
    fill: var(--pub-link-text-color);
  }

  .empty {
    padding: 20px 0;
    color: var(--pub-muted-text-color);
    font-style: italic;
    font-size: 14px;
  }
</style>
