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
      await api.post(`/api/packages/${packageName}/groups`, {
        groupId: selectedGroupId,
      });
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
      await api.post(`/api/packages/${packageName}/groups`, { createGroup });
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
        <div class="membership-copy">
          <a href={`/groups/${group.slug}`}>{group.name}</a>
          {#if group.description}
            <p>{group.description}</p>
          {/if}
        </div>
        <button
          class="remove-button"
          onclick={() => remove(group.id)}
          disabled={busy}
          aria-label={`Remove ${group.name} from this package`}
          title="Remove from group"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M3 6h18" />
            <path d="M8 6V4h8v2" />
            <path d="m19 6-1 14H6L5 6" />
            <path d="M10 11v5M14 11v5" />
          </svg>
        </button>
      </div>
    {:else}
      <p class="empty">This package is not in a group.</p>
    {/each}
  </div>

  <div class="editor">
    <div class="group-picker-row">
      <select
        class="group-picker"
        bind:value={selectedGroupId}
        onchange={handleGroupSelection}
        aria-label="Add package to group"
      >
        <option value="">Select a group</option>
        <option value="__create__">＋ Create a new group</option>
        <optgroup label="Existing groups">
          {#each available.filter((group) => !memberships.some((item) => item.id === group.id)) as group}
            <option value={group.id}>{group.name}</option>
          {/each}
        </optgroup>
      </select>
      <button
        class="primary add-button"
        onclick={addToSelectedGroup}
        disabled={busy || !selectedGroupId}
      >
        Add to group
      </button>
   </div>

    {#if message}<p>{message}</p>{/if}
  </div>
</section>

<Dialog
  bind:open={createDialogOpen}
  title="Create a new group"
  description="Create a visual collection and add this package to it."
  confirmLabel="Create and add"
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
  .option-desc, .empty {
    color: var(--muted-foreground);
    font-size: 14px;
  }

  .memberships, .editor, .dialog-fields {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .memberships {
    overflow: hidden;
    gap: 0;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: color-mix(in srgb, var(--muted) 20%, var(--card));
  }

  .membership {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    min-height: 54px;
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
  }
  .membership:last-child { border-bottom: 0; }
  .membership-copy {
    display: flex;
    min-width: 0;
    flex-direction: column;
    gap: 3px;
  }
  .membership a { color: var(--pub-link-text-color); text-decoration: none; }
  .membership a:hover { text-decoration: underline; }
  .membership-copy p {
    overflow: hidden;
    color: var(--muted-foreground);
    font-size: 12px;
    line-height: 1.4;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .remove-button {
    display: inline-flex;
    width: 34px;
    height: 34px;
    align-items: center;
    justify-content: center;
    padding: 0;
    border-color: transparent;
    color: var(--muted-foreground);
    background: transparent;
  }
  .remove-button:hover:not(:disabled) {
    border-color: color-mix(in srgb, var(--destructive) 30%, transparent);
    color: var(--destructive);
    background: color-mix(in srgb, var(--destructive) 8%, transparent);
  }
  .remove-button:disabled { cursor: not-allowed; opacity: 0.45; }

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
