<script lang="ts">
  import { api, apiErrorMessage } from "$lib/api/client";
  import { confirmDialog } from "$lib/stores/confirm";
  import GroupCard from "$lib/components/GroupCard.svelte";
  import Button from "$lib/components/ui/Button.svelte";
  import Dialog from "$lib/components/ui/Dialog.svelte";
  import type { PackageGroupSummary } from "$lib/types/catalog";

  let groups = $state<PackageGroupSummary[]>([]);
  let query = $state("");
  let message = $state("");
  let loading = $state(true);
  let createDialogOpen = $state(false);
  let createBusy = $state(false);
  let createError = $state("");
  let newName = $state("");
  let newDescription = $state("");
  let openMenuId = $state<string | null>(null);

  async function load() {
    loading = true;
    try {
      const response = await api.get<{ groups: PackageGroupSummary[] }>(
        "/api/groups",
        { params: { q: query } },
      );
      groups = response.groups ?? [];
    } catch (error) {
      message = apiErrorMessage(error, "Unable to load groups.");
    } finally {
      loading = false;
    }
  }

  $effect(() => { load(); });

  function openCreateDialog() {
    createError = "";
    createDialogOpen = true;
  }

  function resetCreateDialog() {
    newName = "";
    newDescription = "";
    createError = "";
  }

  async function createGroup() {
    if (!newName.trim()) return;
    createBusy = true;
    createError = "";
    try {
      await api.post("/api/groups", {
        name: newName,
        description: newDescription,
      });
      createDialogOpen = false;
      resetCreateDialog();
      await load();
    } catch (error) {
      createError = apiErrorMessage(error, "Unable to create group.");
    } finally {
      createBusy = false;
    }
  }

  async function remove(group: PackageGroupSummary) {
    if (!await confirmDialog({
      title: `Delete ${group.name}?`,
      description:
        "This removes the group and its visual memberships. Packages and permissions are unaffected.",
      confirmLabel: "Delete group",
      confirmVariant: "destructive",
    })) return;
    try {
      await api.delete(`/api/groups/${group.id}`);
      await load();
    } catch (error) {
      message = apiErrorMessage(error, "Unable to delete group.");
    }
  }
</script>

<div class="page">
  <div class="heading">
    <div>
      <h1>Groups</h1>
      <p>Moderate visual package collections across the server.</p>
    </div>
    <Button onclick={openCreateDialog}>New group</Button>
  </div>

  <label class="search-field">
    <span class="sr-only">Search groups</span>
    <svg class="search-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
      <circle cx="11" cy="11" r="8" /><path d="m21 21-4.35-4.35" />
    </svg>
    <input type="search" bind:value={query} placeholder="Search groups" />
  </label>

  {#if message}<p class="message">{message}</p>{/if}
  {#if loading}
    <p>Loading groups...</p>
  {:else}
    <div class="group-list">
      {#each groups as group (group.id)}
        <div class="group-list-item">
          <GroupCard {group} />
          <div class="item-menu-wrap">
            <button
              class="item-menu-button"
              aria-label={`Options for ${group.name}`}
              aria-haspopup="menu"
              aria-expanded={openMenuId === group.id}
              onclick={() => (openMenuId = openMenuId === group.id ? null : group.id)}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                <circle cx="5" cy="12" r="1.7" />
                <circle cx="12" cy="12" r="1.7" />
                <circle cx="19" cy="12" r="1.7" />
              </svg>
            </button>
            {#if openMenuId === group.id}
              <div class="item-menu" role="menu">
                <a role="menuitem" href={`/groups/${group.slug}`}>View group</a>
                <button
                  class="danger-item"
                  role="menuitem"
                  onclick={() => {
                    openMenuId = null;
                    remove(group);
                  }}
                >Delete group</button>
              </div>
            {/if}
          </div>
        </div>
      {:else}
        <p>No groups found.</p>
      {/each}
    </div>
  {/if}
</div>

<Dialog
  bind:open={createDialogOpen}
  title="New group"
  description="Create a visual collection for related packages."
  confirmLabel="Create group"
  busy={createBusy}
  confirmDisabled={!newName.trim()}
  onConfirm={createGroup}
  onCancel={resetCreateDialog}
>
  {#snippet body()}
    <div class="dialog-fields">
      {#if createError}<p class="dialog-error">{createError}</p>{/if}
      <label>
        <span>Name</span>
        <input bind:value={newName} placeholder="Payments" maxlength="80" />
        <small>A short name shown in search and package listings.</small>
      </label>
      <label>
        <span>Description</span>
        <textarea
          bind:value={newDescription}
          placeholder="Related payment and billing packages"
          maxlength="1000"
        ></textarea>
        <small>Explain what connects the packages in this group.</small>
      </label>
    </div>
  {/snippet}
</Dialog>

<style>
  .page { display: flex; flex-direction: column; gap: 24px; }
  .heading { display: flex; justify-content: space-between; align-items: end; gap: 20px; }
  h1, p { margin: 0; }
  .heading p { color: var(--muted-foreground); }
  input, textarea, button {
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--card);
    color: var(--foreground);
    font: inherit;
  }
  .search-field { position: relative; display: block; width: min(100%, 360px); }
  .search-field input { width: 100%; padding-left: 36px; }
  .search-icon {
    position: absolute;
    top: 50%;
    left: 12px;
    z-index: 1;
    color: var(--muted-foreground);
    pointer-events: none;
    transform: translateY(-50%);
  }
  .group-list { display: flex; flex-direction: column; }
  .group-list-item {
    position: relative;
    padding: 12px 48px 12px 0;
  }
  .item-menu-wrap { position: absolute; top: 20px; right: 0; z-index: 3; }
  .item-menu-button {
    display: inline-flex;
    width: 30px;
    height: 30px;
    align-items: center;
    justify-content: center;
    padding: 0;
    cursor: pointer;
  }
  .item-menu-button:hover { background: var(--accent); }
  .item-menu {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    display: flex;
    width: 170px;
    flex-direction: column;
    padding: 5px;
    border: 1px solid var(--border);
    border-radius: 9px;
    background: var(--popover, var(--card));
    box-shadow: var(--dialog-shadow);
  }
  .item-menu a,
  .item-menu button {
    width: 100%;
    padding: 9px 10px;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--foreground);
    font: inherit;
    font-size: 13px;
    text-align: left;
    text-decoration: none;
    cursor: pointer;
  }
  .item-menu a:hover,
  .item-menu button:hover { background: var(--accent); }
  .item-menu .danger-item { color: var(--destructive); }
  .message, .dialog-error { color: var(--destructive); }
  .dialog-fields { display: flex; flex-direction: column; gap: 18px; }
  .dialog-fields label { display: flex; flex-direction: column; gap: 7px; color: var(--foreground); font-size: 13px; font-weight: 600; }
  .dialog-fields input, .dialog-fields textarea { width: 100%; background: var(--background); }
  .dialog-fields textarea { min-height: 100px; resize: vertical; }
  .dialog-fields small { color: var(--muted-foreground); font-size: 12px; font-weight: 400; }
  .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
  @media (max-width: 640px) {
    .heading { align-items: flex-start; flex-direction: column; }
  }
</style>
