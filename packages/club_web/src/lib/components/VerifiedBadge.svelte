<script lang="ts">
  /**
   * Small verified-publisher indicator. Shown next to a publisher's
   * display name wherever it appears. `size` controls both the dot and
   * the (optional) trailing label.
   */
  interface Props {
    /** When true, renders a compact icon only. When false, shows
     *  "Verified" text next to the icon. */
    iconOnly?: boolean;
    /** Accessible tooltip text. Defaults to "Verified publisher". */
    title?: string;
    /** Inline CSS class pass-through for sizing tweaks in specific
     *  contexts (e.g. larger on headers, smaller in tables). */
    class?: string;
  }

  let {
    iconOnly = false,
    title = 'Verified publisher',
    class: className = '',
  }: Props = $props();
</script>

<span class="badge {className}" {title} aria-label={title}>
  <svg
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
    aria-hidden="true"
  >
    <path
      d="M12 1l2.39 2.39 3.22-.61.61 3.22L20.61 8.39 18 10l2.61 1.61-2.39 2.39-.61 3.22-3.22-.61L12 19l-2.39-2.39-3.22.61-.61-3.22L3.39 11.61 6 10 3.39 8.39l2.39-2.39.61-3.22 3.22.61L12 1z"
    />
    <path
      d="M9 10l2 2 4-4"
      fill="none"
      stroke="var(--primary-foreground, white)"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
  </svg>
  {#if !iconOnly}<span class="label">Verified</span>{/if}
</span>

<style>
  .badge {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    color: var(--primary);
    font-size: 0.75rem;
    font-weight: 600;
    vertical-align: middle;
  }

  .badge svg {
    width: 1em;
    height: 1em;
    flex-shrink: 0;
  }

  .label {
    font-size: 0.7rem;
    letter-spacing: 0.03em;
  }
</style>
