import TurndownService from 'turndown';
import { gfm } from 'turndown-plugin-gfm';
import type { CopyButtonClientOptions } from './types';

const markdownConverter = createMarkdownConverter();

declare global {
	interface Window {
		__starlightCopyButtonInitialized?: boolean;
	}
}

export function setupStarlightCopyButton(options: CopyButtonClientOptions): void {
	if (window.__starlightCopyButtonInitialized) {
		mountCopyButton(options);
		return;
	}

	window.__starlightCopyButtonInitialized = true;
	document.addEventListener('astro:page-load', () => mountCopyButton(options));
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', () => mountCopyButton(options), { once: true });
	} else {
		mountCopyButton(options);
	}
}

function mountCopyButton(options: CopyButtonClientOptions): void {
	const title = document.querySelector<HTMLHeadingElement>('main h1#_top:not([data-page-title])');
	if (!title || title.closest('[data-sl-copy-button-row]')) {
		return;
	}

	const row = document.createElement('div');
	row.className = 'sl-copy-button-row';
	row.dataset.slCopyButtonRow = 'true';
	title.before(row);
	row.append(title);

	const controls = document.createElement('div');
	controls.className = 'sl-copy-button-controls';

	const liveRegion = document.createElement('div');
	liveRegion.className = 'sl-copy-button-live-region';
	liveRegion.setAttribute('aria-live', 'polite');
	liveRegion.setAttribute('aria-atomic', 'true');

	const button = document.createElement('button');
	button.type = 'button';
	button.className = 'sl-copy-button';
	button.setAttribute('title', options.label);
	button.setAttribute('aria-label', options.label);

	const background = document.createElement('div');
	background.className = 'sl-copy-button__bg';
	background.setAttribute('aria-hidden', 'true');

	const icon = document.createElement('span');
	icon.className = 'sl-copy-button__icon';
	icon.setAttribute('aria-hidden', 'true');
	icon.innerHTML =
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75"><path d="M3 19a2 2 0 0 1-1-2V2a2 2 0 0 1 1-1h13a2 2 0 0 1 2 1"/><rect x="6" y="5" width="16" height="18" rx="1.5" ry="1.5"/></svg>';

	const srLabel = document.createElement('span');
	srLabel.className = 'sl-copy-button__sr-only';
	srLabel.textContent = options.label;

	button.append(background, icon, srLabel);

	if (!options.iconOnly) {
		const text = document.createElement('span');
		text.className = 'sl-copy-button__label';
		text.textContent = options.label;
		controls.classList.add('sl-copy-button-controls--with-label');
		button.append(text);
	}

	controls.append(liveRegion, button);
	row.append(controls);

	button.addEventListener('click', async () => {
		try {
			await writeClipboardText(getCopyValue(options, title));
			showFeedback(liveRegion, options.successLabel, options.stateDuration);
		} catch {
			showFeedback(liveRegion, options.errorLabel, Math.min(options.stateDuration, 2000), true);
		}
	});
}

function showFeedback(region: HTMLElement, text: string, visibleMs: number, isError = false): void {
	const existing = region.querySelector<HTMLElement>('.sl-copy-button-feedback');
	if (existing) {
		existing.remove();
	}

	let tooltip: HTMLDivElement | undefined = document.createElement('div');
	tooltip.className = 'sl-copy-button-feedback';
	if (isError) {
		tooltip.classList.add('sl-copy-button-feedback--error');
	}
	tooltip.textContent = text;
	region.append(tooltip);

	void tooltip.offsetWidth;
	requestAnimationFrame(() => tooltip?.classList.add('show'));

	const hideTooltip = () => tooltip?.classList.remove('show');
	const removeTooltip = () => {
		if (!tooltip) return;
		if (parseFloat(getComputedStyle(tooltip).opacity) > 0) return;
		tooltip.remove();
		tooltip = undefined;
	};

	window.setTimeout(hideTooltip, Math.max(500, visibleMs));
	window.setTimeout(removeTooltip, Math.max(1300, visibleMs + 800));
	tooltip.addEventListener('transitioncancel', removeTooltip);
	tooltip.addEventListener('transitionend', removeTooltip);
}

function getCopyValue(options: CopyButtonClientOptions, title: HTMLHeadingElement): string {
	const markdownContent = document.querySelector<HTMLElement>('main .sl-markdown-content');
	if (!markdownContent) {
		throw new Error('Markdown content root was not found.');
	}

	const clone = markdownContent.cloneNode(true) as HTMLElement;
	sanitizeClone(clone);
	const markdownBody = markdownConverter.turndown(clone).trim();

	const sections: string[] = [];
	if (options.includeTitle) {
		const titleText = normalizeWhitespace(title.textContent?.trim() || document.title || 'Untitled');
		sections.push(`${'#'.repeat(options.titleLevel)} ${titleText}`);
	}
	if (markdownBody) {
		sections.push(markdownBody);
	}

	return sections.join('\n\n').trim();
}

function sanitizeClone(root: HTMLElement): void {
	for (const selector of [
		'script',
		'style',
		'noscript',
		'.sl-anchor-link',
		'.expressive-code .copy',
		'[data-pagefind-ignore]',
	]) {
		root.querySelectorAll(selector).forEach((node) => node.remove());
	}
}

function createMarkdownConverter(): TurndownService {
	const turndown = new TurndownService({
		headingStyle: 'atx',
		codeBlockStyle: 'fenced',
		bulletListMarker: '-',
		emDelimiter: '*',
		strongDelimiter: '**',
	});

	turndown.use(gfm);

	turndown.addRule('expressiveCodeBlock', {
		filter: (node) => isElement(node) && node.classList.contains('expressive-code'),
		replacement(_content, node) {
			if (!isElement(node)) {
				return '\n\n';
			}

			const code = node.querySelector('pre code');
			if (!code) {
				return '\n\n';
			}

			const language =
				code.getAttribute('data-language') || code.className.match(/language-([\w-]+)/)?.[1] || '';
			const rawCode = normalizeNewlines(code.textContent || '').replace(/\n$/, '');
			const fence = getFence(rawCode);
			const openingFence = language ? `${fence}${language}` : fence;

			return `\n\n${openingFence}\n${rawCode}\n${fence}\n\n`;
		},
	});

	return turndown;
}

function isElement(node: Node): node is HTMLElement {
	return node.nodeType === Node.ELEMENT_NODE;
}

function getFence(code: string): string {
	const maxBackticks = Math.max(...(code.match(/`+/g) || ['']).map((value) => value.length));
	return '`'.repeat(Math.max(3, maxBackticks + 1));
}

function normalizeWhitespace(text: string): string {
	return text.replace(/\s+/g, ' ').trim();
}

function normalizeNewlines(text: string): string {
	return text.replace(/\r\n?/g, '\n');
}

async function writeClipboardText(text: string): Promise<void> {
	if (navigator.clipboard?.writeText && window.isSecureContext) {
		await navigator.clipboard.writeText(text);
		return;
	}

	const helper = document.createElement('pre');
	Object.assign(helper.style, {
		opacity: '0',
		pointerEvents: 'none',
		position: 'absolute',
		overflow: 'hidden',
		left: '0',
		top: '0',
		width: '20px',
		height: '20px',
		webkitUserSelect: 'auto',
		userSelect: 'all',
	});
	helper.ariaHidden = 'true';
	helper.textContent = text;
	document.body.appendChild(helper);

	const range = document.createRange();
	range.selectNode(helper);
	const selection = getSelection();
	if (!selection) {
		document.body.removeChild(helper);
		throw new Error('Selection API unavailable.');
	}
	selection.removeAllRanges();
	selection.addRange(range);

	let didCopy = false;
	try {
		didCopy = document.execCommand('copy');
	} finally {
		selection.removeAllRanges();
		document.body.removeChild(helper);
	}
	if (!didCopy) {
		throw new Error('Copy command failed.');
	}
}
