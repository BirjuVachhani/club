<script lang="ts">
  import MarkdownRenderer from './MarkdownRenderer.svelte';

  interface Props {
    section: {
      id: string;
      title: string;
      grantedPoints: number;
      maxPoints: number;
      status: string;
      summary: string;
    };
    expanded: boolean;
    ontoggle: () => void;
  }

  let { section, expanded, ontoggle }: Props = $props();

  let statusClass = $derived(
    section.grantedPoints === section.maxPoints
      ? 'passed'
      : section.grantedPoints === 0
        ? 'failed'
        : 'partial',
  );

  type Status = 'passed' | 'partial' | 'failed';
  type Criterion = {
    status: Status;
    glyph: string;
    label: string;
    points: number;
    maxPoints: number;
    titleHtml: string;
    body: string;
  };

  // Pana reports each sub-criterion as `### [*|~|x] N/M points: <title>`,
  // followed by an optional markdown body. Parsing into structured rows
  // lets us render each one as its own container instead of a flat blob
  // of markdown headings.
  function parseCriteria(md: string): Criterion[] {
    const headingRe = /^### \[([*~x])\] (\d+)\/(\d+) points: (.+)$/;
    const out: Criterion[] = [];
    let current: Criterion | null = null;
    for (const line of md.split('\n')) {
      const m = line.match(headingRe);
      if (m) {
        if (current) out.push({ ...current, body: current.body.trim() });
        const mark = m[1] as '*' | '~' | 'x';
        current = {
          status: mark === '*' ? 'passed' : mark === '~' ? 'partial' : 'failed',
          glyph: mark === '*' ? '✓' : mark === '~' ? '~' : '✕',
          label:
            mark === '*' ? 'Passed' : mark === '~' ? 'Partial' : 'Failed',
          points: parseInt(m[2], 10),
          maxPoints: parseInt(m[3], 10),
          titleHtml: renderInline(m[4]),
          body: '',
        };
      } else if (current) {
        current.body += line + '\n';
      }
    }
    if (current) out.push({ ...current, body: current.body.trim() });
    return out;
  }

  function renderInline(md: string): string {
    // Pana titles only use inline code (`backticks`) and bold (**text**).
    // Tokenize code spans first since they have no internal markdown.
    return md
      .split(/(`[^`]+`)/g)
      .map((seg) => {
        if (seg.startsWith('`') && seg.endsWith('`')) {
          return `<code>${escapeHtml(seg.slice(1, -1))}</code>`;
        }
        return escapeHtml(seg).replace(
          /\*\*([^*]+)\*\*/g,
          '<strong>$1</strong>',
        );
      })
      .join('');
  }

  function escapeHtml(s: string): string {
    return s
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  let criteria = $derived(parseCriteria(section.summary));
</script>

<div class="score-section" class:expanded>
  <button class="section-header" onclick={ontoggle}>
    <div class="section-left">
      <span class="status-icon {statusClass}">
        {#if statusClass === 'passed'}
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M20 6L9 17l-5-5" />
          </svg>
        {:else if statusClass === 'failed'}
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="12" cy="12" r="10" />
            <path d="M15 9l-6 6M9 9l6 6" />
          </svg>
        {:else}
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path d="M20 6L9 17l-5-5" />
          </svg>
        {/if}
      </span>
      <span class="section-title">{section.title}</span>
    </div>
    <div class="section-right">
      <span class="section-points" class:partial={statusClass === 'partial'} class:failed={statusClass === 'failed'}>
        {section.grantedPoints}/{section.maxPoints}
      </span>
      <span class="chevron" class:expanded>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </span>
    </div>
  </button>
  <div class="section-content-wrap" class:expanded aria-hidden={!expanded}>
    <div class="section-content">
      {#if criteria.length > 0}
        <ul class="criteria">
          {#each criteria as c, i (i)}
            <li class="criterion {c.status}">
              <div class="criterion-head">
                <span class="criterion-mark {c.status}" aria-label={c.label}>
                  {c.glyph}
                </span>
                <span class="criterion-points">
                  {c.points}<span class="slash">/</span>{c.maxPoints}
                </span>
                <h4 class="criterion-title">{@html c.titleHtml}</h4>
              </div>
              {#if c.body}
                <div class="criterion-body">
                  <MarkdownRenderer content={c.body} />
                </div>
              {/if}
            </li>
          {/each}
        </ul>
      {:else}
        <MarkdownRenderer content={section.summary} />
      {/if}
    </div>
  </div>
</div>

<style>
  .score-section {
    border-bottom: 1px solid var(--pub-divider-color);
  }
  .score-section:last-child {
    border-bottom: none;
  }

  .section-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 18px 14px;
    background: none;
    border: none;
    border-radius: 10px;
    cursor: pointer;
    font-family: inherit;
    text-align: left;
    color: var(--pub-default-text-color);
    transition: background 0.12s ease;
  }
  .section-header:hover {
    background: var(--muted);
  }

  .section-left {
    display: flex;
    align-items: center;
    gap: 14px;
    min-width: 0;
  }

  .status-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .status-icon.passed { color: var(--success, #4caf50); }
  .status-icon.partial { color: var(--warning, #ff9800); }
  .status-icon.failed { color: var(--pub-error-color, #d32f2f); }

  .section-title {
    font-size: 16px;
    font-weight: 500;
    color: var(--pub-heading-text-color);
  }

  .section-right {
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
  }

  .section-points {
    font-size: 16px;
    font-weight: 600;
    color: var(--pub-heading-text-color);
    font-family: var(--pub-code-font-family);
    font-variant-numeric: tabular-nums;
  }
  .section-points.partial { color: var(--warning, #ff9800); }
  .section-points.failed { color: var(--pub-error-color, #d32f2f); }

  .chevron {
    display: flex;
    color: var(--pub-muted-text-color);
    transition: transform 0.28s cubic-bezier(0.22, 1, 0.36, 1);
  }
  .chevron.expanded {
    transform: rotate(180deg);
  }

  /* Animate expand/collapse via grid-template-rows so we transition
     between intrinsic content height and 0 without measuring it.
     The wrapper provides the height; .section-content carries the
     padding/typography so the inner block can stay overflow:hidden. */
  .section-content-wrap {
    display: grid;
    grid-template-rows: 0fr;
    transition:
      grid-template-rows 0.28s cubic-bezier(0.22, 1, 0.36, 1),
      visibility 0s linear 0.28s;
    visibility: hidden;
  }
  .section-content-wrap.expanded {
    grid-template-rows: 1fr;
    visibility: visible;
    transition:
      grid-template-rows 0.28s cubic-bezier(0.22, 1, 0.36, 1),
      visibility 0s linear 0s;
  }

  .section-content {
    min-height: 0;
    overflow: hidden;
    padding: 0 14px 0 48px;
    font-size: 14px;
    line-height: 1.65;
    opacity: 0;
    transform: translateY(-2px);
    transition:
      opacity 0.18s ease,
      transform 0.24s cubic-bezier(0.22, 1, 0.36, 1),
      padding 0.28s cubic-bezier(0.22, 1, 0.36, 1);
  }
  .section-content-wrap.expanded .section-content {
    padding: 4px 14px 28px 48px;
    opacity: 1;
    transform: translateY(0);
    transition:
      opacity 0.22s ease 0.06s,
      transform 0.28s cubic-bezier(0.22, 1, 0.36, 1) 0.04s,
      padding 0.28s cubic-bezier(0.22, 1, 0.36, 1);
  }

  @media (prefers-reduced-motion: reduce) {
    .section-content-wrap,
    .section-content-wrap.expanded,
    .section-content,
    .section-content-wrap.expanded .section-content {
      transition: none;
    }
  }

  /* List of sub-criterion cards inside the expanded panel. */
  .criteria {
    list-style: none;
    margin: 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .criterion {
    padding: 12px 14px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--muted) 55%, transparent);
    border: 1px solid color-mix(in srgb, var(--border) 60%, transparent);
  }

  .criterion-head {
    display: flex;
    align-items: baseline;
    gap: 10px;
    flex-wrap: wrap;
  }

  .criterion-mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
    line-height: 1;
    flex-shrink: 0;
    align-self: center;
    transform: translateY(0);
  }
  .criterion-mark.passed {
    color: var(--success, #4caf50);
    background: color-mix(in srgb, var(--success, #4caf50) 16%, transparent);
  }
  .criterion-mark.partial {
    color: var(--warning, #ff9800);
    background: color-mix(in srgb, var(--warning, #ff9800) 16%, transparent);
  }
  .criterion-mark.failed {
    color: var(--pub-error-color, #d32f2f);
    background: color-mix(in srgb, var(--pub-error-color, #d32f2f) 16%, transparent);
  }

  .criterion-points {
    font-family: var(--pub-code-font-family);
    font-variant-numeric: tabular-nums;
    font-size: 12.5px;
    font-weight: 600;
    color: var(--pub-default-text-color);
    flex-shrink: 0;
  }
  .criterion-points .slash {
    color: var(--pub-muted-text-color);
    font-weight: 400;
    margin: 0 1px;
  }
  .criterion.failed .criterion-points {
    color: var(--pub-error-color, #d32f2f);
  }
  .criterion.partial .criterion-points {
    color: var(--warning, #ff9800);
  }

  .criterion-title {
    margin: 0;
    flex: 1 1 14rem;
    min-width: 0;
    font-size: 14px;
    font-weight: 500;
    line-height: 1.45;
    color: var(--pub-heading-text-color);
  }
  .criterion-title :global(code) {
    font-family: var(--pub-code-font-family);
    font-size: 0.86em;
    padding: 1px 6px;
    border-radius: 4px;
    background: var(--pub-code-background, var(--muted));
    color: var(--pub-default-text-color);
  }

  .criterion-body {
    margin-top: 8px;
    padding-left: 28px;
    color: var(--pub-default-text-color);
  }
  .criterion-body :global(.markdown-body) {
    font-size: 13.5px;
    line-height: 1.6;
    color: var(--pub-muted-text-color);
  }
  .criterion-body :global(.markdown-body * + p),
  .criterion-body :global(.markdown-body * + ul),
  .criterion-body :global(.markdown-body * + ol) {
    margin-top: 0.55rem;
  }
</style>
