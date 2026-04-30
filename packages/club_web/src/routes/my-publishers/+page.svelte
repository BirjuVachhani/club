<script lang="ts">
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';
  import Button from '$lib/components/ui/Button.svelte';
  import { canCreatePublisher } from '$lib/utils/permissions';

  interface MyPublisher {
    publisherId: string;
    displayName: string;
    description?: string | null;
    createdAt: string;
    role: 'admin' | 'member';
  }

  let publishers = $state<MyPublisher[]>([]);
  let loading = $state(true);

  const user = $derived($auth.user);
  const canCreate = $derived(canCreatePublisher(user));

  $effect(() => {
    api
      .get<{ publishers: MyPublisher[] }>('/api/account/publishers')
      .then((data) => (publishers = data.publishers ?? []))
      .catch(() => (publishers = []))
      .finally(() => (loading = false));
  });

  function formatDate(d: string): string {
    return new Date(d).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  }
</script>

<svelte:head><title>My publishers | CLUB</title></svelte:head>

<!--
  Root wrapper is essential: the global `<main>` uses `flex` (row-direction
  by default) so sibling elements here would lay out as columns. Keep a
  single child.
-->
<div class="page">
  <header class="page-header">
    <div class="page-header-text">
      <h1>My publishers</h1>
      <p>Organizations you're a member of.</p>
    </div>
    {#if canCreate}
      <Button onclick={() => goto('/publishers/verify')}>
        Create publisher
      </Button>
    {/if}
  </header>

  {#if loading}
    <div class="empty-state">
      <p>Loading...</p>
    </div>
  {:else if publishers.length === 0}
    <div class="empty-state">
      <div class="empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M3 21h18"/>
          <path d="M5 21V7l8-4v18"/>
          <path d="M19 21V11l-6-4"/>
          <path d="M9 9h.01"/>
          <path d="M9 12h.01"/>
          <path d="M9 15h.01"/>
          <path d="M9 18h.01"/>
        </svg>
      </div>
      <h2>No publishers yet</h2>
      <p>
        Publishers are organizations that own packages — they let a team
        share ownership so packages don't depend on individual accounts.
      </p>
      {#if canCreate}
        <Button onclick={() => goto('/publishers/verify')}>
          Verify a domain
        </Button>
        <p class="hint">
          We'll give you a DNS TXT record to add on the domain you want
          to claim. Once it's live, the publisher is yours.
        </p>
      {:else}
        <p class="hint">
          You need at least the <code>member</code> role to claim a
          publisher. Ask a server admin to adjust your role or add you as
          a member of an existing publisher.
        </p>
      {/if}
    </div>
  {:else}
    <div class="list">
      {#each publishers as p (p.publisherId)}
        <article class="card">
          <h2><a href={`/publishers/${p.publisherId}`}>{p.displayName}</a></h2>
          <p class="pid">{p.publisherId}</p>
          <div class="meta">
            <span class="role-badge role-{p.role}">{p.role}</span>
            <span class="created">Registered {formatDate(p.createdAt)}</span>
          </div>
          {#if p.description}
            <p class="desc">{p.description}</p>
          {/if}
        </article>
      {/each}
    </div>
  {/if}
</div>

<style>
  .page {
    width: 100%;
    min-width: 0;
  }

  .page-header {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    justify-content: space-between;
    gap: 0.75rem 1rem;
    margin-bottom: 1.5rem;
  }

  .page-header-text h1 {
    margin: 0 0 0.25rem;
    font-size: 1.375rem;
    font-weight: 700;
  }

  .page-header-text p {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
  }

  .list {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .card {
    padding: 1rem 1.25rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
  }

  .card h2 {
    margin: 0 0 0.1rem;
    font-size: 1rem;
    font-weight: 600;
  }

  .card h2 a {
    color: var(--primary);
    text-decoration: none;
  }

  .card h2 a:hover {
    text-decoration: underline;
  }

  .pid {
    margin: 0 0 0.5rem;
    font-family: var(--font-mono);
    font-size: 0.75rem;
    color: var(--muted-foreground);
  }

  .meta {
    display: flex;
    flex-wrap: wrap;
    gap: 0.25rem 0.75rem;
    align-items: center;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
  }

  .role-badge {
    padding: 0.125rem 0.4rem;
    border-radius: 3px;
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .role-admin {
    background: color-mix(in srgb, var(--primary) 15%, transparent);
    color: var(--primary);
  }

  .role-member {
    background: var(--muted);
    color: var(--muted-foreground);
  }

  .desc {
    margin: 0.5rem 0 0;
    color: var(--foreground);
    font-size: 0.875rem;
  }

  /* Centered empty state — shown both for "loading" and "no publishers"
     so the page doesn't shift once data arrives. */
  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    padding: 3.5rem 1.5rem;
    border: 1px dashed var(--border);
    border-radius: 12px;
    background: var(--card);
    gap: 0.75rem;
    margin-top: 0.5rem;
  }

  .empty-icon {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 64px;
    height: 64px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--primary) 10%, transparent);
    color: var(--primary);
    margin-bottom: 0.25rem;
  }

  .empty-state h2 {
    margin: 0;
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--foreground);
  }

  .empty-state p {
    margin: 0;
    color: var(--muted-foreground);
    font-size: 0.875rem;
    max-width: 34rem;
    line-height: 1.55;
  }

  .empty-state .hint {
    margin-top: 0.25rem;
    font-size: 0.8125rem;
  }
</style>
