import { marked, type Tokens } from 'marked';
import hljs from 'highlight.js';
import DOMPurify from 'dompurify';

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function highlightCode(code: string, lang?: string): string {
  if (lang && hljs.getLanguage(lang)) {
    try {
      return hljs.highlight(code, { language: lang }).value;
    } catch {
      // Fall through to auto-detection.
    }
  }

  try {
    return hljs.highlightAuto(code).value;
  } catch {
    return escapeHtml(code);
  }
}

marked.setOptions({
  gfm: true,
  breaks: false
});

marked.use({
  renderer: {
    code({ text, lang }: Tokens.Code): string {
      const language = lang?.trim().toLowerCase() ?? '';
      const languageClass = language ? ` language-${escapeHtml(language)}` : '';
      const html = highlightCode(text, language || undefined);
      return `<pre><code class="hljs${languageClass}">${html}</code></pre>`;
    }
  }
});

export function renderMarkdown(content: string): string {
  const raw = marked.parse(content);
  // marked.parse can return string | Promise<string>; in synchronous mode it returns string.
  let html = typeof raw === 'string' ? raw : '';
  // Wrap tables in a horizontal scroll container. On narrow viewports
  // wide tables would otherwise be clipped by the page-level `overflow-x:
  // hidden` guard — keeping them scrollable preserves readability.
  html = html
    .replace(/<table(\s|>)/g, '<div class="md-table-wrap"><table$1')
    .replace(/<\/table>/g, '</table></div>');
  return DOMPurify.sanitize(html, {
    ADD_TAGS: ['highlight', 'details', 'summary'],
    ADD_ATTR: ['class', 'open']
  });
}
