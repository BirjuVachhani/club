/**
 * Lock viewport scroll while a modal/dialog is open. Returns an
 * `unlock` function that restores whatever overflow values were in
 * place before. Locks BOTH `<html>` and `<body>` because depending
 * on browser and root CSS, either may carry the scroll context
 * (this app sets `overflow-x: hidden` on both, which can route the
 * vertical scroll to `<html>` and cause `body.overflow=hidden` alone
 * to leak through).
 *
 * The lock supports stacking — if dialog A opens, then B opens on top,
 * each captures the value at the moment it locks (which is already
 * "hidden" for B), and unlocks pop the stack in reverse so A's unlock
 * still restores the original page-scroll behavior.
 */
export function lockScroll(): () => void {
  if (typeof document === 'undefined') return () => {};

  const html = document.documentElement;
  const body = document.body;

  const prevHtmlOverflow = html.style.overflow;
  const prevBodyOverflow = body.style.overflow;

  html.style.overflow = 'hidden';
  body.style.overflow = 'hidden';

  let unlocked = false;
  return () => {
    if (unlocked) return;
    unlocked = true;
    html.style.overflow = prevHtmlOverflow;
    body.style.overflow = prevBodyOverflow;
  };
}
