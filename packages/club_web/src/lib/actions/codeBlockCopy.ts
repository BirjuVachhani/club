const SVG_NS = 'http://www.w3.org/2000/svg';

function createSvg(attrs: Record<string, string>, children: SVGElement[]): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg');
  for (const [k, v] of Object.entries(attrs)) svg.setAttribute(k, v);
  for (const child of children) svg.appendChild(child);
  return svg;
}

function svgEl(tag: string, attrs: Record<string, string>): SVGElement {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}

const baseSvgAttrs: Record<string, string> = {
  width: '14',
  height: '14',
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  'stroke-width': '2',
  'stroke-linecap': 'round',
  'stroke-linejoin': 'round'
};

function createCopyIcon(): SVGSVGElement {
  return createSvg(baseSvgAttrs, [
    svgEl('rect', { x: '9', y: '9', width: '13', height: '13', rx: '2' }),
    svgEl('path', { d: 'M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1' })
  ]);
}

function createCheckIcon(): SVGSVGElement {
  return createSvg(baseSvgAttrs, [
    svgEl('polyline', { points: '20 6 9 17 4 12' })
  ]);
}

function attachCopyButtons(root: HTMLElement): void {
  const pres = root.querySelectorAll<HTMLPreElement>('pre');
  for (const pre of pres) {
    if (pre.parentElement?.classList.contains('code-wrap')) continue;
    if (pre.dataset.noCopy === 'true') continue;

    // Absolute children of a horizontally-scrolling <pre> scroll with the
    // content, so anchor the button to a wrapper instead.
    const wrap = document.createElement('div');
    wrap.className = 'code-wrap';
    pre.parentNode?.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'code-copy-btn';
    btn.title = 'Copy code';
    btn.setAttribute('aria-label', 'Copy code');
    btn.appendChild(createCopyIcon());

    btn.addEventListener('click', () => {
      const code = pre.querySelector('code');
      const text = code?.textContent ?? pre.textContent ?? '';
      navigator.clipboard.writeText(text).catch(() => {});
      btn.replaceChildren(createCheckIcon());
      setTimeout(() => {
        btn.replaceChildren(createCopyIcon());
      }, 1500);
    });

    wrap.appendChild(btn);
  }
}

export function codeBlockCopyAction(node: HTMLElement) {
  const run = () => queueMicrotask(() => attachCopyButtons(node));

  run();

  const observer = new MutationObserver((mutations) => {
    const shouldRefresh = mutations.some(
      (m) => m.type === 'childList' && (m.addedNodes.length > 0 || m.removedNodes.length > 0)
    );
    if (shouldRefresh) run();
  });

  observer.observe(node, {
    subtree: true,
    childList: true
  });

  return {
    destroy() {
      observer.disconnect();
    }
  };
}
