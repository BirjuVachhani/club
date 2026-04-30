<script lang="ts">
  import { onMount } from 'svelte';

  onMount(() => {
    const canvas = document.getElementById('hero2Halftone') as HTMLCanvasElement;
    if (!canvas) return;
    const parent = canvas.parentElement;
    if (!parent) return;

    canvas.width = parent.offsetWidth;
    canvas.height = parent.offsetHeight;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const gap = 12;
    const cols = Math.ceil(canvas.width / gap);
    const rows = Math.ceil(canvas.height / gap);
    const w = canvas.width;
    const h = canvas.height;

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = c * gap + gap / 2;
        const y = r * gap + gap / 2;

        const nx = x / w;
        const ny = y / h;
        // Fade at top (0->0.25) and bottom (0.75->1), peak in middle band
        const topFade = Math.min(ny / 0.25, 1);
        const bottomFade = Math.min((1 - ny) / 0.3, 1);
        const vertFade = topFade * bottomFade;
        const horizFade = 1 - nx * 0.3;
        // Dark hole in center for content readability
        const cx = w * 0.5, cy = h * 0.55;
        const distCenter = Math.hypot(x - cx, y - cy) / (w * 0.35);
        const centerHole = Math.min(distCenter, 1);

        let intensity = vertFade * horizFade * centerHole;
        intensity *= 0.7 + Math.random() * 0.3;
        intensity = Math.max(0, Math.min(1, intensity));

        if (intensity < 0.03) continue;

        const maxR = gap * 0.42;
        const radius = maxR * intensity;
        const alpha = 0.4 + intensity * 0.5;

        ctx.beginPath();
        ctx.arc(x, y, radius, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(255, 79, 24, ${alpha})`;
        ctx.fill();
      }
    }
  });
</script>

<!--
  Hero2: Halftone Orange with top+bottom fade variant.
  Dots fade in from the top, peak in the middle band, fade out at bottom.
  Dark center hole for content readability.

  Usage: Replace the hero canvas in +page.svelte with <Hero2 />
-->
<canvas class="hero2-canvas" id="hero2Halftone"></canvas>

<style>
  .hero2-canvas {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    z-index: 0;
  }
</style>
