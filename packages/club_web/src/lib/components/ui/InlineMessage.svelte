<script lang="ts">
  /**
   * Small inline status message shown above a form or list. Success /
   * error / info tones each get a colored band via semantic tokens.
   * Prefer this over hand-rolled `<div>` blocks repeated across admin
   * pages.
   */
  type Tone = 'info' | 'error' | 'success';

  interface Props {
    message: string;
    tone?: Tone;
  }

  let { message, tone = 'info' }: Props = $props();
</script>

{#if message}
  <div class="msg msg-{tone}" role={tone === 'error' ? 'alert' : 'status'}>
    {message}
  </div>
{/if}

<style>
  .msg {
    padding: 0.6rem 0.75rem;
    border-radius: 6px;
    font-size: 0.875rem;
    margin-bottom: 1rem;
  }

  .msg-info {
    background: var(--muted);
    color: var(--foreground);
    border: 1px solid var(--border);
  }

  .msg-success {
    background: color-mix(in srgb, var(--success) 12%, var(--card));
    color: var(--success);
    border: 1px solid color-mix(in srgb, var(--success) 35%, transparent);
  }

  .msg-error {
    background: color-mix(in srgb, var(--destructive) 12%, var(--card));
    color: var(--destructive);
    border: 1px solid color-mix(in srgb, var(--destructive) 35%, transparent);
  }
</style>
