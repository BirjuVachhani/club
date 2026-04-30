<script lang="ts">
  import { renderMarkdown } from '$lib/utils/markdown';

  interface Props {
    content: string;
  }

  let { content }: Props = $props();

  let html = $derived(renderMarkdown(content));
</script>

<div class="markdown-body">
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

  /* Tailwind preflight zeroes out list-style on ul/ol; restore the
     bullets/numbers for prose. Nested ul re-overrides to `none` below
     to render the tree-style branches instead. */
  .markdown-body :global(ul) {
    list-style: disc outside;
  }
  .markdown-body :global(ol) {
    list-style: decimal outside;
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
