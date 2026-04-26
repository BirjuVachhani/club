<script lang="ts">
  interface Props {
    count: number;
    onReview: () => void;
  }

  let { count, onReview }: Props = $props();
</script>

{#if count > 0}
  <div class="bar" role="status" aria-live="polite">
    <div class="inner">
      <span class="msg">
        <svg
          class="icon"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" />
          <line x1="12" y1="9" x2="12" y2="13" />
          <line x1="12" y1="17" x2="12.01" y2="17" />
        </svg>
        <strong>{count} package version{count === 1 ? '' : 's'}</strong>
        <span class="muted">missing tarballs on disk.</span>
      </span>
      <button class="review" onclick={onReview}>
        Review
        <svg
          width="13"
          height="13"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <polyline points="9 18 15 12 9 6" />
        </svg>
      </button>
    </div>
  </div>
{/if}

<style>
  .bar {
    background: color-mix(in srgb, var(--destructive) 12%, var(--card));
    border-bottom: 1px solid color-mix(in srgb, var(--destructive) 35%, transparent);
    color: var(--foreground);
    font-size: 13px;
  }

  .inner {
    max-width: 80rem; /* matches header's max-w-7xl */
    margin: 0 auto;
    /* Mirror the header's px-3 sm:px-4 md:px-6 horizontal padding so
       the message and Review button line up vertically with the logo
       and avatar in the header below. */
    padding: 8px 12px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  @media (min-width: 640px) {
    .inner {
      padding-left: 16px;
      padding-right: 16px;
    }
  }
  @media (min-width: 768px) {
    .inner {
      padding-left: 24px;
      padding-right: 24px;
    }
  }

  .msg {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    line-height: 1.4;
  }

  .icon {
    color: var(--destructive);
    flex-shrink: 0;
  }

  .msg strong {
    font-weight: 600;
    color: var(--foreground);
  }

  .muted {
    color: var(--muted-foreground);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .review {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 4px 10px 4px 12px;
    border: 1px solid color-mix(in srgb, var(--destructive) 50%, transparent);
    border-radius: 6px;
    background: transparent;
    color: var(--destructive);
    font-size: 12px;
    font-weight: 600;
    font-family: inherit;
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.12s ease, border-color 0.12s ease;
  }
  .review:hover {
    background: color-mix(in srgb, var(--destructive) 14%, transparent);
    border-color: color-mix(in srgb, var(--destructive) 70%, transparent);
  }

  @media (max-width: 480px) {
    .muted {
      display: none;
    }
  }
</style>
