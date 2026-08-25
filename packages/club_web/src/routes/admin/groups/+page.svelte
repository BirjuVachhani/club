<script lang="ts">
  import { api, apiErrorMessage } from "$lib/api/client";
  import { confirmDialog } from "$lib/stores/confirm";
  import GroupCard from "$lib/components/GroupCard.svelte";
  import type { PackageGroupSummary } from "$lib/types/catalog";

  let groups = $state<PackageGroupSummary[]>([]);
  let query = $state("");
  let message = $state("");
  let loading = $state(true);
  let newName = $state("");
  let newDescription = $state("");

  async function load() {
    loading = true;
    try {
      const response = await api.get<{ groups: PackageGroupSummary[] }>("/api/groups", { params: { q: query } });
      groups = response.groups ?? [];
    } catch (error) { message = apiErrorMessage(error, "Unable to load groups."); }
    finally { loading = false; }
  }
  $effect(() => { load(); });

  async function createGroup() {
    if (!newName.trim()) return;
    try {
      await api.post("/api/groups", { name: newName, description: newDescription });
      newName = ""; newDescription = ""; await load();
    } catch (error) { message = apiErrorMessage(error, "Unable to create group."); }
  }

  async function remove(group: PackageGroupSummary) {
    if (!await confirmDialog({ title: `Delete ${group.name}?`, description: "This removes the group and its visual memberships. Packages and permissions are unaffected.", confirmLabel: "Delete group", confirmVariant: "destructive" })) return;
    try { await api.delete(`/api/groups/${group.id}`); await load(); }
    catch (error) { message = apiErrorMessage(error, "Unable to delete group."); }
  }
</script>

<div class="page">
  <div class="heading"><div><h1>Groups</h1><p>Moderate visual package collections across the server.</p></div><input bind:value={query} placeholder="Search groups" /></div>
  <div class="create"><input bind:value={newName} placeholder="New group name" /><input bind:value={newDescription} placeholder="Description" /><button onclick={createGroup} disabled={!newName.trim()}>Create group</button></div>
  {#if message}<p class="message">{message}</p>{/if}
  {#if loading}<p>Loading groups...</p>{:else}<div class="grid">{#each groups as group}<div><GroupCard {group} /><button onclick={() => remove(group)}>Delete</button></div>{:else}<p>No groups found.</p>{/each}</div>{/if}
</div>

<style>
  .page { display: flex; flex-direction: column; gap: 24px; } .heading { display: flex; justify-content: space-between; align-items: end; gap: 20px; } h1, p { margin: 0; } .heading p { color: var(--muted-foreground); } input, button { padding: 10px 12px; border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--foreground); } .create { display: flex; flex-wrap: wrap; gap: 10px; } .grid { display: grid; gap: 20px; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); } .grid > div { display: flex; flex-direction: column; gap: 8px; } button { align-self: end; cursor: pointer; } .message { color: var(--destructive); }
</style>
