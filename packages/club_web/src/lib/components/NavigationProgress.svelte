<script lang="ts">
  import { navigating } from '$app/state';

  // SvelteKit's `navigating` is truthy only during client-side router
  // navigations — exactly the window where the browser shows no native
  // tab spinner (no document request happens in an SPA). This bar fills
  // that gap with an NProgress-style trickle.

  let width = $state(0);
  let visible = $state(false);

  let trickle: ReturnType<typeof setInterval> | null = null;
  let hideTimer: ReturnType<typeof setTimeout> | null = null;
  let showTimer: ReturnType<typeof setTimeout> | null = null;

  function clearTimers() {
    if (trickle) { clearInterval(trickle); trickle = null; }
    if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; }
    if (showTimer) { clearTimeout(showTimer); showTimer = null; }
  }

  function begin() {
    clearTimers();
    // Brief delay so instant (cached) navigations don't flash a bar.
    showTimer = setTimeout(() => {
      visible = true;
      width = 8;
      // Trickle towards 92% with diminishing increments — it never
      // reaches 100% on its own; `finish()` snaps it there.
      trickle = setInterval(() => {
        const remaining = 92 - width;
        if (remaining > 0) width += Math.max(0.4, remaining * 0.06);
      }, 240);
    }, 120);
  }

  function finish() {
    clearTimers();
    // Navigation resolved before the bar ever showed — nothing to do.
    if (!visible) { width = 0; return; }
    width = 100;
    hideTimer = setTimeout(() => {
      visible = false;
      width = 0;
    }, 280);
  }

  $effect(() => {
    if (navigating.to) begin();
    else finish();
  });
</script>

{#if visible}
  <div class="nav-progress" role="presentation">
    <div class="nav-progress-bar" style="width: {width}%"></div>
  </div>
{/if}

<style>
  .nav-progress {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    height: 3px;
    z-index: 200;
    pointer-events: none;
  }
  .nav-progress-bar {
    height: 100%;
    background: var(--primary, #2563eb);
    border-radius: 0 2px 2px 0;
    box-shadow:
      0 0 8px color-mix(in srgb, var(--primary, #2563eb) 70%, transparent),
      0 0 2px var(--primary, #2563eb);
    transition: width 220ms ease-out;
  }
</style>
