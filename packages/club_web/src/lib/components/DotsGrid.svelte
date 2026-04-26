<script lang="ts">
  import { onMount } from 'svelte';
  import { browser } from '$app/environment';

  interface Props {
    /** Extra classes applied to the canvas (positioning is the caller's responsibility). */
    class?: string;
    /** Pixel spacing between dot centers. */
    gap?: number;
    /** Max dot radius as a fraction of `gap`. */
    maxRadiusRatio?: number;
    /** Intensity threshold below which dots are skipped entirely. */
    minIntensity?: number;

    /** Explicit `r, g, b` string. When set, overrides `lightColor` / `darkColor`. */
    dotColor?: string | null;
    /** Dot color (`r, g, b`) used in light theme. */
    lightColor?: string;
    /** Dot color (`r, g, b`) used in dark theme. */
    darkColor?: string;
    /** Alpha at min intensity. `null` picks a theme-appropriate default. */
    alphaBase?: number | null;
    /** Alpha added on top of `alphaBase` at max intensity. `null` = theme default. */
    alphaRange?: number | null;
    /** Whether to re-detect the `.dark-theme` class on `<html>` and redraw on change. */
    watchTheme?: boolean;

    /** Apply a vertical fade across the grid. */
    vertFade?: boolean;
    /** Direction of vertical fade: dense at `top`, `bottom`, or in the `middle`. */
    vertFadeDirection?: 'top' | 'bottom' | 'middle';
    /** Horizontal fade strength (0 = none, 1 = fades to zero on the right). */
    horizFadeStrength?: number;

    /** Carve out a low-density region to improve readability of overlaid content. */
    centerHole?: boolean;
    /** Center-hole X position (0–1 across width). */
    centerHoleX?: number;
    /** Center-hole Y position (0–1 across height). */
    centerHoleY?: number;
    /** Center-hole radius as a fraction of width. */
    centerHoleRadius?: number;

    /** Per-cell randomness floor. */
    noiseMin?: number;
    /** Per-cell randomness range added on top of `noiseMin`. */
    noiseRange?: number;
    /** Seed for deterministic noise; defaults to a random value per mount. */
    seed?: number;
  }

  let {
    class: className = '',
    gap = 12,
    maxRadiusRatio = 0.42,
    minIntensity = 0.03,
    dotColor = null,
    lightColor = '0, 0, 0',
    darkColor = '255, 79, 24',
    alphaBase = null,
    alphaRange = null,
    watchTheme = true,
    vertFade = true,
    vertFadeDirection = 'top',
    horizFadeStrength = 0.3,
    centerHole = true,
    centerHoleX = 0.5,
    centerHoleY = 0.65,
    centerHoleRadius = 0.35,
    noiseMin = 0.7,
    noiseRange = 0.3,
    seed = (Math.random() * 0xffffffff) >>> 0,
  }: Props = $props();

  let canvas: HTMLCanvasElement | null = $state(null);

  function noise(r: number, c: number): number {
    let h = seed ^ (r * 374761393 + c * 668265263);
    h = Math.imul(h ^ (h >>> 15), 0x85ebca6b);
    h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35);
    h = (h ^ (h >>> 16)) >>> 0;
    return noiseMin + (h / 0xffffffff) * noiseRange;
  }

  function draw() {
    if (!canvas) return;
    const parent = canvas.parentElement;
    if (!parent) return;

    const w = parent.offsetWidth;
    const h = parent.offsetHeight;
    if (w === 0 || h === 0) return;

    canvas.width = w;
    canvas.height = h;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const isDark =
      watchTheme && document.documentElement.classList.contains('dark-theme');
    const color = dotColor ?? (isDark ? darkColor : lightColor);
    const baseA = alphaBase ?? (isDark ? 0.4 : 0.15);
    const rangeA = alphaRange ?? (isDark ? 0.5 : 0.35);

    const cols = Math.ceil(w / gap);
    const rows = Math.ceil(h / gap);
    const maxR = gap * maxRadiusRatio;

    ctx.clearRect(0, 0, w, h);

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * gap + gap / 2;
        const y = r * gap + gap / 2;
        const nx = x / w;
        const ny = y / h;

        let vFade = 1;
        if (vertFade) {
          if (vertFadeDirection === 'top') vFade = 1 - ny;
          else if (vertFadeDirection === 'bottom') vFade = ny;
          else vFade = 1 - Math.abs(ny - 0.5) * 2;
        }
        const hFade = 1 - nx * horizFadeStrength;

        let hole = 1;
        if (centerHole) {
          const cx = w * centerHoleX;
          const cy = h * centerHoleY;
          // Scale the hole off the larger dimension so the halo stays
          // readable on portrait/tall viewports (mobile, tablet), where
          // tying it to `w` alone shrinks it below the content block.
          const d = Math.hypot(x - cx, y - cy) / (Math.max(w, h) * centerHoleRadius);
          hole = Math.min(d, 1);
        }

        let intensity = vFade * hFade * hole * noise(r, c);
        intensity = Math.max(0, Math.min(1, intensity));
        if (intensity < minIntensity) continue;

        ctx.beginPath();
        ctx.arc(x, y, maxR * intensity, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(${color}, ${baseA + intensity * rangeA})`;
        ctx.fill();
      }
    }
  }

  onMount(() => {
    draw();

    const ro = new ResizeObserver(() => draw());
    if (canvas?.parentElement) ro.observe(canvas.parentElement);

    let mo: MutationObserver | null = null;
    if (watchTheme) {
      mo = new MutationObserver(() => requestAnimationFrame(draw));
      mo.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['class'],
      });
    }

    return () => {
      ro.disconnect();
      mo?.disconnect();
    };
  });

  $effect(() => {
    // Touch every config prop so the effect re-runs on any change.
    void [
      gap,
      maxRadiusRatio,
      minIntensity,
      dotColor,
      lightColor,
      darkColor,
      alphaBase,
      alphaRange,
      watchTheme,
      vertFade,
      vertFadeDirection,
      horizFadeStrength,
      centerHole,
      centerHoleX,
      centerHoleY,
      centerHoleRadius,
      noiseMin,
      noiseRange,
      seed,
    ];
    if (browser && canvas) draw();
  });
</script>

<canvas bind:this={canvas} class={className}></canvas>

<style>
  /* Defaults: fill the nearest positioned ancestor as a background layer.
     The parent should set `position: relative` (or similar) and `overflow: hidden`.
     Pass your own class to override any of these. */
  canvas {
    display: block;
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    z-index: 0;
    pointer-events: none;
  }
</style>
