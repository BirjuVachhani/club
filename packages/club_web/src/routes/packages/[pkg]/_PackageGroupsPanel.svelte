<script lang="ts">
  import { api, apiErrorMessage } from "$lib/api/client";
  import Dialog from "$lib/components/ui/Dialog.svelte";
  import type { PackageGroupSummary } from "$lib/types/catalog";

  interface Props {
    packageName: string;
    publishers?: Array<{ publisherId: string; displayName: string }>;
  }

  let { packageName, publishers = [] }: Props = $props();
  let memberships = $state<PackageGroupSummary[]>([]);
  let available = $state<PackageGroupSummary[]>([]);
  let selectedGroupId = $state("");
  let sourceGroupId = $state("");
  let createDialogOpen = $state(false);
  let name = $state("");
  let description = $state("");
  let publisherId = $state("");
  let busy = $state(false);
  let message = $state("");
  let dialogError = $state("");

  async function load() {
    const [current, groups] = await Promise.all([
      api.get<{ groups: PackageGroupSummary[] }>(`/api/packages/${packageName}/groups`),
      api.get<{ groups: PackageGroupSummary[] }>("/api/groups"),
    ]);
    memberships = current.groups ?? [];
    available = groups.groups ?? [];
  }

  $effect(() => {
    void packageName;
    load().catch(() => {});
  });

  function handleGroupSelection() {
    if (selectedGroupId !== "__create__") return;
    selectedGroupId = "";
    dialogError = "";
    createDialogOpen = true;
  }

  async function addToSelectedGroup() {
    if (!selectedGroupId) return;
    busy = true;
    message = "";
    try {
      if (sourceGroupId) {
        await api.post(`/api/packages/${packageName}/groups/move`, {
          fromGroupId: sourceGroupId,
          toGroupId: selectedGroupId,
        });
      } else {
        await api.post(`/api/packages/${packageName}/groups`, {
          groupId: selectedGroupId,
        });
      }
      sourceGroupId = "";
      selectedGroupId = "";
      message = "Groups updated.";
      await load();
    } catch (error) {
      message = apiErrorMessage(error, "Unable to update groups.");
    } finally {
      busy = false;
    }
  }

  async function createAndAddGroup() {
    if (!name.trim()) return;
    busy = true;
    dialogError = "";
    try {
      const createGroup = {
        name,
        description,
        ...(publisherId ? { publisherId } : {}),
      };
      if (sourceGroupId) {
        await api.post(`/api/packages/${packageName}/groups/move`, {
          fromGroupId: sourceGroupId,
          createGroup,
        });
      } else {
        await api.post(`/api/packages/${packageName}/groups`, { createGroup });
      }
      sourceGroupId = "";
      name = "";
      description = "";
      publisherId = "";
      createDialogOpen = false;
      message = "Group created and package added.";
      await load();
    } catch (error) {
      dialogError = apiErrorMessage(error, "Unable to create the group.");
    } finally {
      busy = false;
    }
  }

  function resetCreateForm() {
    name = "";
    description = "";
    publisherId = "";
    dialogError = "";
  }

  async function remove(groupId: string) {
    busy = true;
    try {
      await api.delete(`/api/packages/${packageName}/groups/${groupId}`);
      await load();
    } catch (error) {
      message = apiErrorMessage(error, "Unable to remove group.");
    } finally {
      busy = false;
    }
  }
</script>

<section class="admin-section">
  <h3>Groups</h3>
  <p class="option-desc">
    Visual collections containing this package. Groups do not change ownership
    or publishing permissions.
  </p>

  <div class="memberships">
    {#each memberships as group (group.id)}
      <div class="membership">
        <a href={`/groups/${group.slug}`}>{group.name}</a>
        <div>
          <button onclick={() => sourceGroupId = group.id}>Move</button>
          <button onclick={() => remove(group.id)} disabled={busy}>Remove</button>
        </div>
      </div>
    {:else}
      <p class="empty">This package is not in a group.</p>
    {/each}
  </div>

  <div class="editor">
    {#if sourceGroupId}
      <p class="notice">
        Moving replaces the selected membership and keeps all others.
      </p>
    {/if}

    <div class="group-picker-row">
      <select
        class="group-picker"
        bind:value={selectedGroupId}
        onchange={handleGroupSelection}
        aria-label={sourceGroupId ? "Move package to group" : "Add package to group"}
      >
        <option value="">Select a group</option>
        <option value="__create__">＋ Create a new group</option>
        <optgroup label="Existing groups">
          {#each available.filter((group) => group.id !== sourceGroupId) as group}
            <option value={group.id}>{group.name}</option>
          {/each}
        </optgroup>
      </select>
      <button
        class="primary add-button"
        onclick={addToSelectedGroup}
        disabled={busy || !selectedGroupId}
      >
        {sourceGroupId ? "Move package" : "Add to group"}
      </button>
      {#if sourceGroupId}
        <button class="cancel-button" onclick={() => sourceGroupId = ""}>
          Cancel
        </button>
      {/if}
    </div>

    {#if message}<p>{message}</p>{/if}
  </div>
</section>

<Dialog
  bind:open={createDialogOpen}
  title="Create a new group"
  description={sourceGroupId
    ? "Create a group and move this package into it. Other group memberships remain unchanged."
    : "Create a visual collection and add this package to it."}
  confirmLabel={sourceGroupId ? "Create and move" : "Create and add"}
  busy={busy}
  confirmDisabled={!name.trim()}
  onConfirm={createAndAddGroup}
  onCancel={resetCreateForm}
>
  {#snippet body()}
    <div class="dialog-fields">
      {#if dialogError}<p class="dialog-error">{dialogError}</p>{/if}
      <label>
        <span>Name</span>
        <input bind:value={name} placeholder="Payments" />
      </label>
      <label>
        <span>Description</span>
        <textarea
          bind:value={description}
          placeholder="Related payment and billing packages"
        ></textarea>
      </label>
      <label>
        <span>Owner</span>
        <select bind:value={publisherId}>
          <option value="">Me</option>
          {#each publishers as publisher}
            <option value={publisher.publisherId}>
              {publisher.displayName}
            </option>
          {/each}
        </select>
      </label>
    </div>
  {/snippet}
</Dialog>

<style>
  .admin-section {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 24px 0;
    border-top: 1px solid var(--border);
  }

  h3, p { margin: 0; }
  .option-desc, .empty, .notice {
    color: var(--muted-foreground);
    font-size: 14px;
  }

  .memberships, .editor, .dialog-fields {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .membership {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
  }
  .membership div { display: flex; gap: 8px; }

  .group-picker-row {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 8px;
  }

  .group-picker {
    width: min(100%, 320px);
    padding-right: 38px;
    appearance: none;
    -webkit-appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 24 24' fill='none' stroke='%23888' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='m6 9 6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 12px center;
  }

  .add-button {
    width: auto;
    min-width: 112px;
    white-space: nowrap;
  }

  .cancel-button { width: auto; }

  button, input, textarea, select {
    padding: 9px 11px;
    border: 1px solid var(--border);
    border-radius: 7px;
    background: var(--card);
    color: var(--foreground);
    font: inherit;
  }
  button { cursor: pointer; }
  .primary {
    background: var(--primary);
    color: var(--primary-foreground);
  }

  .dialog-fields label {
    display: flex;
    flex-direction: column;
    gap: 6px;
    color: var(--foreground);
    font-size: 13px;
    font-weight: 600;
  }
  .dialog-fields input,
  .dialog-fields textarea,
  .dialog-fields select { width: 100%; }
  textarea { min-height: 88px; resize: vertical; }
  .dialog-error { color: var(--destructive); font-size: 13px; }

  @media (max-width: 560px) {
    .group-picker { width: 100%; }
  }
</style>
