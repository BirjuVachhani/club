<script lang="ts">
  import { page } from '$app/state';
  import { api } from '$lib/api/client';
  import Tabs from '$lib/components/ui/Tabs.svelte';
  import VerifiedBadge from '$lib/components/VerifiedBadge.svelte';
  import { auth } from '$lib/stores/auth';
  import { canManagePublisher, isServerAdmin } from '$lib/utils/permissions';
  import type { Snippet } from 'svelte';

  interface Props {
    children: Snippet;
  }
  let { children }: Props = $props();

  const id = $derived(page.params.id);

  let publisher = $state<any>(null);
  let loading = $state(true);
  // Role of the signed-in user within this publisher. Null means not a
  // member. The server returns this inline on GET /api/publishers/<id>
  // so we never need a second round-trip.
  let myRole = $state<'admin' | 'member' | null>(null);

  $effect(() => {
    // Re-load when the publisher id changes.
    const current = id;
    loading = true;
    publisher = null;
    myRole = null;

    api
      .get<any>(`/api/publishers/${current}`)
      .then((p) => {
        publisher = p;
        myRole = (p.callerRole as 'admin' | 'member' | null) ?? null;
      })
      .catch(() => (publisher = null))
      .finally(() => (loading = false));
  });

  const user = $derived($auth.user);
  const canAdmin = $derived(
    canManagePublisher(user, { isPublisherAdmin: myRole === 'admin' }),
  );
  const canSeeActivity = $derived(myRole !== null || isServerAdmin(user));

  const tabs = $derived([
    { label: 'Packages', href: `/publishers/${id}` },
    {
      label: 'Admin',
      href: `/publishers/${id}/admin`,
      hidden: !canAdmin,
    },
    {
      label: 'Activity log',
      href: `/publishers/${id}/activity`,
      hidden: !canSeeActivity,
    },
  ]);
</script>

<svelte:head>
  <title>{publisher?.displayName ?? 'Publisher'} | CLUB</title>
</svelte:head>

<div class="publisher-detail">
  {#if loading}
    <p class="loading">Loading...</p>
  {:else if publisher}
    <header class="publisher-header">
      <div class="title-row">
        <h1 class="display-name">{publisher.displayName}</h1>
        {#if publisher.verified}
          <VerifiedBadge class="header-badge" />
        {/if}
      </div>
      {#if publisher.verified}
        <!-- For verified publishers, the ID IS the domain — label it as
             such so viewers don't have to infer it from the dots. -->
        <p class="publisher-id">
          <span class="id-label">Domain</span>
          <span class="id-value">{publisher.domain ?? publisher.publisherId}</span>
        </p>
      {:else}
        <p class="publisher-id">
          <span class="id-label">Internal ID</span>
          <span class="id-value">{publisher.publisherId}</span>
        </p>
      {/if}
      <div class="meta">
        {#if publisher.websiteUrl}
          <a href={publisher.websiteUrl} target="_blank" rel="noopener" class="link">{publisher.websiteUrl}</a>
        {/if}
        {#if publisher.contactEmail}
          <a href={`mailto:${publisher.contactEmail}`} class="link">{publisher.contactEmail}</a>
        {/if}
      </div>
      {#if publisher.description}
        <p class="description">{publisher.description}</p>
      {/if}
    </header>

    <Tabs {tabs} pathname={page.url.pathname} />

    {@render children()}
  {:else}
    <p>Publisher not found.</p>
  {/if}
</div>

<style>
  .publisher-detail {
    width: 100%;
    max-width: 64rem;
    margin: 0 auto;
    min-width: 0;
  }

  .publisher-header {
    padding: 1rem 0 1.5rem;
  }

  .display-name {
    font-size: 1.375rem;
    font-weight: 700;
    margin: 0;
    color: var(--foreground);
    word-break: break-word;
  }
  @media (min-width: 640px) {
    .display-name { font-size: 1.75rem; }
  }

  .title-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 0.25rem;
  }

  .title-row :global(.header-badge) {
    font-size: 1rem;
  }

  .id-label {
    font-size: 0.65rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--muted-foreground);
    margin-right: 0.4rem;
  }

  .id-value {
    font-family: var(--font-mono);
    color: var(--foreground);
  }

  .publisher-id {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    color: var(--muted-foreground);
    margin: 0 0 0.5rem;
  }

  .meta {
    display: flex;
    gap: 1rem;
    flex-wrap: wrap;
    margin: 0.5rem 0;
  }

  .link {
    color: var(--primary);
    text-decoration: none;
    font-size: 0.875rem;
  }

  .link:hover {
    text-decoration: underline;
  }

  .description {
    margin: 1rem 0 0;
    color: var(--foreground);
    line-height: 1.6;
  }

  .loading {
    padding: 2rem;
    text-align: center;
    color: var(--muted-foreground);
  }
</style>
