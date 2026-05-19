<script lang="ts">
  /**
   * A single shimmering placeholder block. Compose several of these to
   * sketch the shape of content that is still loading, so the page can
   * paint its layout immediately instead of blocking on data.
   */
  interface Props {
    width?: string;
    height?: string;
    radius?: string;
  }

  let { width = '100%', height = '1rem', radius = '6px' }: Props = $props();
</script>

<span
  class="skeleton"
  style="width: {width}; height: {height}; border-radius: {radius};"
  aria-hidden="true"
></span>

<style>
  .skeleton {
    display: block;
    flex-shrink: 0;
    background: linear-gradient(
      90deg,
      var(--secondary) 25%,
      color-mix(in srgb, var(--secondary) 55%, var(--accent)) 50%,
      var(--secondary) 75%
    );
    background-size: 200% 100%;
    animation: skeleton-shimmer 1.4s ease-in-out infinite;
  }

  @keyframes skeleton-shimmer {
    0% {
      background-position: 200% 0;
    }
    100% {
      background-position: -200% 0;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .skeleton {
      animation: none;
    }
  }
</style>
