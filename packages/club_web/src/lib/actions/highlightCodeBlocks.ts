import hljs from 'highlight.js';

function highlightCodeBlocks(root: HTMLElement): void {
  const blocks = root.querySelectorAll<HTMLElement>('pre code:not(.hljs)');
  for (const block of blocks) {
    hljs.highlightElement(block);
  }
}

export function highlightCodeAction(node: HTMLElement) {
  const runHighlight = () => {
    // Wait until the current DOM update is committed before walking the subtree.
    queueMicrotask(() => highlightCodeBlocks(node));
  };

  runHighlight();

  const observer = new MutationObserver((mutations) => {
    const shouldRefresh = mutations.some((mutation) => {
      if (mutation.type === 'characterData') {
        return true;
      }
      if (mutation.type !== 'childList') {
        return false;
      }
      return (
        mutation.addedNodes.length > 0 ||
        mutation.removedNodes.length > 0
      );
    });

    if (shouldRefresh) {
      runHighlight();
    }
  });

  observer.observe(node, {
    subtree: true,
    childList: true,
    characterData: true
  });

  return {
    destroy() {
      observer.disconnect();
    }
  };
}
