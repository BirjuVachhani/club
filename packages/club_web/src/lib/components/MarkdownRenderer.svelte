<script lang="ts">
  import { renderMarkdown } from '$lib/utils/markdown';

  interface Props {
    content: string;
  }

  let { content }: Props = $props();

  let html = $derived(renderMarkdown(content));
  let container: HTMLDivElement;

  const copyIcon = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>`;
  const checkIcon = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`;

  function createIcon(svgString: string): SVGElement {
    const template = document.createElement('template');
    template.innerHTML = svgString.trim();
    return template.content.firstChild as SVGElement;
  }

  $effect(() => {
    // Re-run when html changes
    void html;
    if (!container) return;

    // Wrap each <pre> in a .code-wrap so the copy button can anchor to
    // the wrapper instead of the scrolling <pre>. Absolute children of
    // a horizontally-scrolling container scroll with the content, which
    // is why the button used to drift left when the code overflowed.
    for (const pre of container.querySelectorAll<HTMLPreElement>('pre')) {
      if (pre.parentElement?.classList.contains('code-wrap')) continue;

      pre.style.position = '';

      const wrap = document.createElement('div');
      wrap.className = 'code-wrap';
      pre.parentNode?.insertBefore(wrap, pre);
      wrap.appendChild(pre);

      const btn = document.createElement('button');
      btn.className = 'code-copy-btn';
      btn.title = 'Copy code';
      btn.appendChild(createIcon(copyIcon));

      btn.addEventListener('click', () => {
        const code = pre.querySelector('code');
        const text = code?.textContent ?? pre.textContent ?? '';
        navigator.clipboard.writeText(text);
        btn.replaceChildren(createIcon(checkIcon));
        setTimeout(() => {
          btn.replaceChildren(createIcon(copyIcon));
        }, 1500);
      });

      wrap.appendChild(btn);
    }
  });
</script>

<div class="markdown-body" bind:this={container}>
  {@html html}
</div>

<style>
  .markdown-body {
    line-height: 1.7;
    word-wrap: break-word;
    overflow-wrap: break-word;
    font-size: 0.98rem;
  }

  .markdown-body :global(> :first-child) {
    margin-top: 0;
  }

  .markdown-body :global(> :last-child) {
    margin-bottom: 0;
  }

  .markdown-body :global(p),
  .markdown-body :global(ul),
  .markdown-body :global(ol),
  .markdown-body :global(pre),
  .markdown-body :global(.code-wrap),
  .markdown-body :global(table),
  .markdown-body :global(.md-table-wrap),
  .markdown-body :global(blockquote),
  .markdown-body :global(hr) {
    margin: 0;
  }

  .markdown-body :global(.code-wrap) {
    position: relative;
  }

  .markdown-body :global(ul),
  .markdown-body :global(ol) {
    padding-left: 1.4rem;
  }

  .markdown-body :global(li + li) {
    margin-top: 0.2rem;
  }

  .markdown-body :global(li) {
    line-height: 1.5;
  }

  /* Tree-style nested lists (ToC, etc.) */
  .markdown-body :global(ul ul),
  .markdown-body :global(ol ul),
  .markdown-body :global(ul ol) {
    padding-left: 1rem;
    margin-top: 0;
  }

  .markdown-body :global(ul ul li),
  .markdown-body :global(ol ul li) {
    position: relative;
    padding-left: 0.75rem;
    margin-top: 0;
    list-style: none;
  }

  /* Vertical line connecting siblings */
  .markdown-body :global(ul ul li::after),
  .markdown-body :global(ol ul li::after) {
    content: '';
    position: absolute;
    left: -0.25rem;
    top: 0;
    bottom: 0;
    border-left: 1px solid var(--pub-divider-color);
  }

  /* Horizontal branch to item */
  .markdown-body :global(ul ul li::before),
  .markdown-body :global(ol ul li::before) {
    content: '';
    position: absolute;
    left: -0.25rem;
    top: 0.7em;
    width: 0.5rem;
    border-bottom: 1px solid var(--pub-divider-color);
  }

  /* Last child: stop the vertical line at the branch */
  .markdown-body :global(ul ul li:last-child::after),
  .markdown-body :global(ol ul li:last-child::after) {
    bottom: auto;
    height: 0.7em;
  }

  .markdown-body :global(ul ul > li + li),
  .markdown-body :global(ol ul > li + li) {
    margin-top: 0;
  }

  .markdown-body :global(li > ul),
  .markdown-body :global(li > ol) {
    margin-top: 0;
  }

  .markdown-body :global(h1) {
    font-size: 2.25em;
    font-weight: 700;
    line-height: 1.15;
    border-bottom: 1px solid var(--pub-divider-color);
    padding-bottom: 0.3em;
    margin: 0;
  }

  .markdown-body :global(h2) {
    font-size: 1.75em;
    font-weight: 700;
    line-height: 1.2;
    border-bottom: 1px solid var(--pub-divider-color);
    padding-bottom: 0.3em;
    margin: 0;
  }

  .markdown-body :global(h3) {
    font-size: 1.4em;
    font-weight: 600;
    line-height: 1.25;
    margin: 0;
  }

  .markdown-body :global(h4) {
    font-size: 1.2em;
    font-weight: 600;
    line-height: 1.25;
    margin: 0;
  }

  .markdown-body :global(h5),
  .markdown-body :global(h6) {
    font-weight: 600;
    line-height: 1.25;
    margin: 0;
  }

  .markdown-body :global(hr) {
    border: 0;
    border-top: 1px solid var(--pub-divider-color);
  }

  .markdown-body :global(* + p),
  .markdown-body :global(* + ul),
  .markdown-body :global(* + ol),
  .markdown-body :global(* + pre),
  .markdown-body :global(* + .code-wrap),
  .markdown-body :global(* + table),
  .markdown-body :global(* + .md-table-wrap),
  .markdown-body :global(* + blockquote),
  .markdown-body :global(* + hr) {
    margin-top: 1rem;
  }

  .markdown-body :global(* + .md-table-wrap) {
    margin-top: 1.5rem;
  }
  .markdown-body :global(.md-table-wrap + *) {
    margin-top: 1.5rem;
  }

  .markdown-body :global(* + h1) {
    margin-top: 2.5rem;
  }

  .markdown-body :global(* + h2) {
    margin-top: 2.1rem;
  }

  .markdown-body :global(* + h3),
  .markdown-body :global(* + h4),
  .markdown-body :global(* + h5),
  .markdown-body :global(* + h6) {
    margin-top: 1.6rem;
  }

  .markdown-body :global(h1 + p),
  .markdown-body :global(h1 + ul),
  .markdown-body :global(h1 + ol),
  .markdown-body :global(h1 + pre),
  .markdown-body :global(h1 + table),
  .markdown-body :global(h1 + blockquote),
  .markdown-body :global(h2 + p),
  .markdown-body :global(h2 + ul),
  .markdown-body :global(h2 + ol),
  .markdown-body :global(h2 + pre),
  .markdown-body :global(h2 + table),
  .markdown-body :global(h2 + blockquote),
  .markdown-body :global(h3 + p),
  .markdown-body :global(h3 + ul),
  .markdown-body :global(h3 + ol),
  .markdown-body :global(h3 + pre),
  .markdown-body :global(h3 + table),
  .markdown-body :global(h3 + blockquote),
  .markdown-body :global(h4 + p),
  .markdown-body :global(h4 + ul),
  .markdown-body :global(h4 + ol),
  .markdown-body :global(h4 + pre),
  .markdown-body :global(h4 + table),
  .markdown-body :global(h4 + blockquote),
  .markdown-body :global(h5 + p),
  .markdown-body :global(h5 + ul),
  .markdown-body :global(h5 + ol),
  .markdown-body :global(h5 + pre),
  .markdown-body :global(h5 + table),
  .markdown-body :global(h5 + blockquote),
  .markdown-body :global(h6 + p),
  .markdown-body :global(h6 + ul),
  .markdown-body :global(h6 + ol),
  .markdown-body :global(h6 + pre),
  .markdown-body :global(h6 + table),
  .markdown-body :global(h6 + blockquote) {
    margin-top: 0.75rem;
  }

  .markdown-body :global(h1 + h2),
  .markdown-body :global(h2 + h3),
  .markdown-body :global(h3 + h4),
  .markdown-body :global(h4 + h5),
  .markdown-body :global(h5 + h6) {
    margin-top: 1rem;
  }

  .markdown-body :global(img) {
    max-width: 100%;
    height: auto;
    border-radius: 0.75rem;
  }

  /* Badge/shield images — inline, no rounded corners */
  .markdown-body :global(a > img) {
    display: inline-block;
    border-radius: 3px;
    vertical-align: middle;
  }
  .markdown-body :global(p > a:has(> img)) {
    display: inline;
    margin-right: 4px;
  }

  .markdown-body :global(p + p) {
    margin-top: 0.9rem;
  }

  .markdown-body :global(.md-table-wrap) {
    max-width: 100%;
    overflow: hidden;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    border: 1px solid var(--pub-divider-color);
    border-radius: 0.75rem;
    scrollbar-width: thin;
    scrollbar-color: transparent transparent;
    transition: scrollbar-color 0.2s ease;
  }
  .markdown-body :global(.md-table-wrap:hover),
  .markdown-body :global(.md-table-wrap:focus-within) {
    scrollbar-color: color-mix(in srgb, var(--pub-muted-text-color) 35%, transparent) transparent;
  }
  .markdown-body :global(.md-table-wrap::-webkit-scrollbar) {
    height: 8px;
  }
  .markdown-body :global(.md-table-wrap::-webkit-scrollbar-track) {
    background: transparent;
  }
  .markdown-body :global(.md-table-wrap::-webkit-scrollbar-thumb) {
    background: transparent;
    border-radius: 999px;
    transition: background 0.2s ease;
  }
  .markdown-body :global(.md-table-wrap:hover::-webkit-scrollbar-thumb),
  .markdown-body :global(.md-table-wrap:focus-within::-webkit-scrollbar-thumb) {
    background: color-mix(in srgb, var(--pub-muted-text-color) 30%, transparent);
  }
  .markdown-body :global(.md-table-wrap::-webkit-scrollbar-thumb:hover) {
    background: color-mix(in srgb, var(--pub-muted-text-color) 55%, transparent);
  }
  .markdown-body :global(table) {
    border-collapse: collapse;
    width: 100%;
  }

  .markdown-body :global(th),
  .markdown-body :global(td) {
    border-top: 1px solid var(--pub-divider-color);
    border-left: 1px solid var(--pub-divider-color);
    padding: 8px 12px;
    text-align: left;
  }
  .markdown-body :global(tr > :first-child) {
    border-left: 0;
  }
  .markdown-body :global(thead tr:first-child > *) {
    border-top: 0;
  }
  .markdown-body :global(table:not(:has(thead)) tbody tr:first-child > *) {
    border-top: 0;
  }

  .markdown-body :global(thead) {
    background: var(--muted);
  }

  .markdown-body :global(th) {
    font-size: 0.78rem;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--pub-muted-text-color);
    border-bottom: 2px solid var(--pub-divider-color);
    padding: 10px 12px;
    white-space: nowrap;
  }

  .markdown-body :global(tbody tr:nth-child(even)) {
    background: color-mix(in srgb, var(--muted) 45%, transparent);
  }

  .markdown-body :global(blockquote) {
    border-left: 4px solid var(--pub-divider-color);
    padding: 0 0 0 16px;
    color: var(--pub-muted-text-color);
  }

  .markdown-body :global(blockquote > :first-child) {
    margin-top: 0;
  }

  .markdown-body :global(blockquote > :last-child) {
    margin-bottom: 0;
  }

  /* Code block copy button */
  .markdown-body :global(.code-copy-btn) {
    position: absolute;
    top: 8px;
    right: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 30px;
    height: 30px;
    border: 1px solid var(--pub-code-border);
    border-radius: 6px;
    background: var(--pub-code-background);
    color: var(--pub-code-muted-color);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.15s, color 0.15s, border-color 0.15s;
  }
  .markdown-body :global(.code-wrap:hover .code-copy-btn),
  .markdown-body :global(.code-wrap:focus-within .code-copy-btn) {
    opacity: 1;
  }
  .markdown-body :global(.code-copy-btn:hover) {
    color: var(--foreground);
    border-color: var(--pub-muted-text-color);
  }
  /* Touch/coarse pointers (phones, tablets) can't hover — keep the
     button visible so it's actually reachable. */
  @media (hover: none), (pointer: coarse) {
    .markdown-body :global(.code-copy-btn) {
      opacity: 1;
    }
  }

  /* Details/summary (pana issue reports) */
  .markdown-body :global(details) {
    border: 1px solid var(--pub-divider-color);
    border-radius: 8px;
    padding: 0;
    overflow: hidden;
  }
  .markdown-body :global(details + details) {
    margin-top: 8px;
  }
  .markdown-body :global(details summary) {
    padding: 10px 14px;
    cursor: pointer;
    font-weight: 500;
    font-size: 0.9rem;
    color: var(--pub-default-text-color);
    background: var(--muted);
    list-style: none;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .markdown-body :global(details summary::before) {
    content: '▶';
    font-size: 0.65rem;
    color: var(--pub-muted-text-color);
    transition: transform 0.15s;
    flex-shrink: 0;
  }
  .markdown-body :global(details[open] summary::before) {
    transform: rotate(90deg);
  }
  .markdown-body :global(details summary::-webkit-details-marker) {
    display: none;
  }
  .markdown-body :global(details > :not(summary)) {
    padding: 0 14px;
  }
  .markdown-body :global(details > :nth-child(2)) {
    padding-top: 12px;
  }
  .markdown-body :global(details > :last-child) {
    padding-bottom: 12px;
  }
  .markdown-body :global(details pre) {
    font-size: 0.85rem;
  }
</style>
