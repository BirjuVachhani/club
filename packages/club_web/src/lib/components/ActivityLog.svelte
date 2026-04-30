<script lang="ts">
  /**
   * Renders a list of audit-log entries with cursor pagination. Used by
   * the per-package, per-publisher, and per-user activity pages.
   *
   * The owner fetches the data and passes it in — this component does
   * not own the fetch lifecycle. When `hasMore` is true, a "Load more"
   * button fires `onLoadMore`.
   */
  import { timeAgo } from '$lib/utils/date';
  import Button from './ui/Button.svelte';

  export interface Entry {
    id: string;
    createdAt: string;
    summary: string;
    agent?: { email: string; displayName: string } | null;
  }

  interface Props {
    entries: Entry[];
    loading: boolean;
    hasMore: boolean;
    emptyMessage?: string;
    showAgent?: boolean;
    onLoadMore: () => void;
  }

  let {
    entries,
    loading,
    hasMore,
    emptyMessage = 'No activity recorded.',
    showAgent = true,
    onLoadMore,
  }: Props = $props();
</script>

{#if loading && entries.length === 0}
  <p class="empty">Loading...</p>
{:else if entries.length === 0}
  <p class="empty">{emptyMessage}</p>
{:else}
  <div class="list">
    {#each entries as e (e.id)}
      <div class="row">
        <span class="time">{timeAgo(e.createdAt)}</span>
        <div class="detail">
          <p class="summary">{e.summary}</p>
          {#if showAgent && e.agent}
            <p class="agent">by {e.agent.displayName} ({e.agent.email})</p>
          {/if}
        </div>
      </div>
    {/each}
  </div>
  {#if hasMore}
    <div class="more">
      <Button variant="outline" disabled={loading} onclick={onLoadMore}>
        {loading ? 'Loading...' : 'Load more'}
      </Button>
    </div>
  {/if}
{/if}

<style>
  .list {
    display: flex;
    flex-direction: column;
  }

  .row {
    display: grid;
    grid-template-columns: 140px 1fr;
    gap: 1rem;
    padding: 0.875rem 0;
    border-bottom: 1px solid var(--border);
  }

  .time {
    color: var(--muted-foreground);
    font-size: 0.8125rem;
  }

  .summary {
    margin: 0 0 0.2rem;
    font-size: 0.875rem;
    color: var(--foreground);
    line-height: 1.5;
  }

  .agent {
    margin: 0;
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }

  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }

  .more {
    display: flex;
    justify-content: center;
    padding: 1rem 0;
  }
</style>
