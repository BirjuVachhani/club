<script lang="ts">
  import PackageCard from "$lib/components/PackageCard.svelte";
  import Button from "$lib/components/ui/Button.svelte";
  import Dialog from "$lib/components/ui/Dialog.svelte";
  import { api, apiErrorMessage } from "$lib/api/client";
  import { confirmDialog } from "$lib/stores/confirm";

  let { data } = $props();
  let savedGroup = $state<any>(null);
  let packageOverride = $state<any[] | null>(null);
  let group = $derived(savedGroup ?? data.group);
  let packages = $derived(packageOverride ?? data.packages.packages ?? []);
  let errorMessage = $state("");
  let toastMessage = $state("");
  let toastVisible = $state(false);
  let toastTimer: ReturnType<typeof setTimeout> | null = null;
  let menuOpen = $state(false);
  let reorderDialogOpen = $state(false);
  let reorderBusy = $state(false);
  let reorderError = $state("");
  let reorderDraft = $state<any[]>([]);
  let draggedPackageName = $state<string | null>(null);
  let dragOverPackageName = $state<string | null>(null);

  function showToast(text: string) {
    toastMessage = text;
    toastVisible = true;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toastVisible = false), 3200);
  }

  function closeMenu() { menuOpen = false; }

  function openReorderDialog() {
    closeMenu();
    reorderDraft = [...packages];
    reorderError = "";
    endDrag();
    reorderDialogOpen = true;
  }

  function reorderPackage(sourceName: string, targetName: string) {
    if (sourceName === targetName) return;
    const source = reorderDraft.findIndex((pkg: any) => pkg.name === sourceName);
    const target = reorderDraft.findIndex((pkg: any) => pkg.name === targetName);
    if (source < 0 || target < 0) return;
    const next = [...reorderDraft];
    const [moved] = next.splice(source, 1);
    next.splice(target, 0, moved);
    reorderDraft = next;
  }

  function startDrag(event: DragEvent, packageName: string) {
    draggedPackageName = packageName;
    dragOverPackageName = null;
    event.dataTransfer?.setData("text/plain", packageName);
    if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
  }

  function dragOver(event: DragEvent, packageName: string) {
    event.preventDefault();
    if (!draggedPackageName || draggedPackageName === packageName) return;
    dragOverPackageName = packageName;
    if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
  }

  function dropPackage(event: DragEvent, packageName: string) {
    event.preventDefault();
    const source = draggedPackageName ?? event.dataTransfer?.getData("text/plain");
    if (source) reorderPackage(source, packageName);
    endDrag();
  }

  function endDrag() {
    draggedPackageName = null;
    dragOverPackageName = null;
  }

  function handleReorderKey(event: KeyboardEvent, index: number) {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.preventDefault();
    const target = event.key === "ArrowUp" ? index - 1 : index + 1;
    if (target < 0 || target >= reorderDraft.length) return;
    const next = [...reorderDraft];
    const [moved] = next.splice(index, 1);
    next.splice(target, 0, moved);
    reorderDraft = next;
  }

  async function saveOrder() {
    reorderBusy = true;
    reorderError = "";
    try {
      await api.put(`/api/groups/${group.id}/packages/order`, {
        packages: reorderDraft.map((pkg: any) => pkg.name),
      });
      packageOverride = [...reorderDraft];
      reorderDialogOpen = false;
      showToast("Package order updated.");
    } catch (error) {
      reorderError = apiErrorMessage(error, "Unable to reorder packages.");
    } finally {
      reorderBusy = false;
    }
  }

  // Group editing dialog.
  let editDialogOpen = $state(false);
  let editBusy = $state(false);
  let editError = $state("");
  let name = $state("");
  let description = $state("");

  function openEditDialog() {
    name = group.name;
    description = group.description ?? "";
    editError = "";
    editDialogOpen = true;
  }

  function resetEditDialog() {
    name = group.name;
    description = group.description ?? "";
    editError = "";
  }

  async function save() {
    if (!name.trim()) return;
    editBusy = true;
    editError = "";
    try {
      savedGroup = await api.put(`/api/groups/${group.id}`, {
        name,
        description,
      });
      editDialogOpen = false;
      showToast("Group updated.");
    } catch (error) {
      editError = apiErrorMessage(error, "Unable to update the group.");
    } finally {
      editBusy = false;
    }
  }

  async function deleteGroup() {
    if (
      !await confirmDialog({
        title: `Delete ${group.name}?`,
        description:
          "This removes the group and its visual memberships. Packages and permissions are unaffected.",
        confirmLabel: "Delete group",
        confirmVariant: "destructive",
      })
    ) return;
    try {
      await api.delete(`/api/groups/${group.id}`);
      window.location.href = "/packages?type=groups";
    } catch (error) {
      editError = apiErrorMessage(error, "Unable to delete the group.");
    }
  }

  // Edit-packages dialog.
  let packageDialogOpen = $state(false);
  let packageSearch = $state("");
  let allPackageNames = $state<string[]>([]);
  let selectedPackages = $state<Set<string>>(new Set());
  let packageListLoading = $state(false);
  let packageEditBusy = $state(false);
  let packageEditError = $state("");

  const currentPackageNames = $derived<Set<string>>(
    new Set<string>(packages.map((pkg: any) => pkg.name as string)),
  );
  const filteredPackageNames = $derived(
    allPackageNames.filter((packageName) =>
      packageName.toLowerCase().includes(packageSearch.trim().toLowerCase()),
    ),
  );

  async function openPackageDialog() {
    packageSearch = "";
    selectedPackages = new Set(currentPackageNames);
    packageEditError = "";
    packageDialogOpen = true;
    if (allPackageNames.length > 0) return;

    packageListLoading = true;
    try {
      const names: string[] = [];
      let page: string | undefined;
      do {
        const result = await api.get<{
          packages: string[];
          nextPageToken?: string | null;
        }>("/api/packages", {
          params: page ? { page } : undefined,
        });
        names.push(...(result.packages ?? []));
        page = result.nextPageToken ?? undefined;
      } while (page);
      allPackageNames = [...new Set(names)].sort((a, b) => a.localeCompare(b));
    } catch (error) {
      packageEditError = apiErrorMessage(error, "Unable to load packages.");
    } finally {
      packageListLoading = false;
    }
  }

  function togglePackage(packageName: string) {
    const next = new Set(selectedPackages);
    if (next.has(packageName)) next.delete(packageName);
    else next.add(packageName);
    selectedPackages = next;
  }

  async function savePackageSelection() {
    packageEditBusy = true;
    packageEditError = "";
    try {
      await api.put(`/api/groups/${group.id}/packages`, {
        packages: [...selectedPackages],
      });
      packageDialogOpen = false;
      window.location.reload();
    } catch (error) {
      packageEditError = apiErrorMessage(
        error,
        "Unable to update the selected packages.",
      );
    } finally {
      packageEditBusy = false;
    }
  }

  function resetPackageDialog() {
    packageSearch = "";
    selectedPackages = new Set(currentPackageNames);
    packageEditError = "";
  }


</script>

<svelte:head><title>{group.name} group</title></svelte:head>

<div class="group-page">
  <header>
    <div class="label">PACKAGE GROUP</div>
    <div class="title-row">
      <h1>{group.name}</h1>
      {#if group.canManage}
        <div class="header-actions">
          <Button onclick={openPackageDialog}>Edit packages</Button>
          <div class="menu-wrap">
            <button
              class="more-button"
              aria-label="Group actions"
              aria-haspopup="menu"
              aria-expanded={menuOpen}
              onclick={() => (menuOpen = !menuOpen)}
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                <circle cx="5" cy="12" r="1.7" />
                <circle cx="12" cy="12" r="1.7" />
                <circle cx="19" cy="12" r="1.7" />
              </svg>
            </button>
            {#if menuOpen}
              <div class="action-menu" role="menu">
                <button role="menuitem" onclick={() => { closeMenu(); openEditDialog(); }}>Edit group</button>
                <button role="menuitem" onclick={openReorderDialog} disabled={packages.length < 2}>Reorder packages</button>
                <button class="danger-item" role="menuitem" onclick={() => { closeMenu(); deleteGroup(); }}>Delete group</button>
              </div>
            {/if}
          </div>
        </div>
      {/if}
    </div>
    {#if group.description}<p class="group-description">{group.description}</p>{/if}
    <div class="group-meta">
      <span>{group.packageCount} {group.packageCount === 1 ? "package" : "packages"}</span>
      {#if group.owner}<span>Managed by {group.owner.displayName}</span>{/if}
    </div>
    {#if errorMessage}<p class="message error-message">{errorMessage}</p>{/if}
  </header>

  {#if packages.length}
    <div class="package-list">
      {#each packages as pkg (pkg.name)}
        <PackageCard {pkg} />
      {/each}
    </div>
  {:else}
    <div class="empty">This group has no packages visible to you.</div>
  {/if}
</div>

<Dialog
  bind:open={editDialogOpen}
  title="Edit group"
  description="Update how this group appears in search and package listings."
  confirmLabel="Save changes"
  busy={editBusy}
  confirmDisabled={!name.trim()}
  onConfirm={save}
  onCancel={resetEditDialog}
  size="lg"
>
  {#snippet body()}
    <div class="management-panel">
      {#if editError}<p class="form-error">{editError}</p>{/if}
      <div class="edit-form">
        <label class="field">
          <span class="field-label">Group name</span>
          <input
            class="field-control name-control"
            bind:value={name}
            placeholder="e.g. Payments"
            maxlength="80"
            aria-describedby="group-name-hint"
          />
          <span id="group-name-hint" class="field-hint">
            A short, recognizable name shown in search and package listings.
          </span>
        </label>
        <label class="field">
          <span class="field-label">Description</span>
          <textarea
            class="field-control description-control"
            bind:value={description}
            placeholder="Describe what connects the packages in this group."
            maxlength="1000"
            aria-describedby="group-description-hint"
          ></textarea>
          <span id="group-description-hint" class="field-hint">
            Help people understand when and why they would use this collection.
          </span>
        </label>
      </div>
    </div>
  {/snippet}
</Dialog>

<Dialog
  bind:open={packageDialogOpen}
  title="Edit packages"
  description="Select the packages that belong in this group. Untick a package to remove it."
  confirmLabel="Save packages"
  busy={packageEditBusy}
  confirmDisabled={packageListLoading}
  onConfirm={savePackageSelection}
  onCancel={resetPackageDialog}
  size="lg"
>
  {#snippet body()}
    <div class="package-picker">
      {#if packageEditError}<p class="form-error">{packageEditError}</p>{/if}
      <label class="search-field">
        <span class="field-label">Search packages</span>
        <input
          class="field-control"
          type="search"
          bind:value={packageSearch}
          placeholder="Search by package name"
        />
      </label>

      <div class="picker-summary">
        <span>{selectedPackages.size} selected</span>
        <span>{filteredPackageNames.length} shown</span>
      </div>

      {#if packageListLoading}
        <div class="picker-state">Loading packages...</div>
      {:else if filteredPackageNames.length === 0}
        <div class="picker-state">No packages match your search.</div>
      {:else}
        <div class="package-options">
          {#each filteredPackageNames as packageName (packageName)}
            {@const wasIncluded = currentPackageNames.has(packageName)}
            <label class="package-option">
              <input
                type="checkbox"
                checked={selectedPackages.has(packageName)}
                onchange={() => togglePackage(packageName)}
              />
              <span class="option-name">{packageName}</span>
              {#if wasIncluded}
                <span class="included-label">Currently included</span>
              {/if}
            </label>
          {/each}
        </div>
      {/if}
    </div>
  {/snippet}
</Dialog>

<Dialog
  bind:open={reorderDialogOpen}
  title="Reorder packages"
  description="Arrange packages in the order they should appear in this group."
  confirmLabel="Save order"
  busy={reorderBusy}
  onConfirm={saveOrder}
  size="lg"
>
  {#snippet body()}
    <div class="reorder-list" role="list">
      {#if reorderError}<p class="form-error">{reorderError}</p>{/if}
      {#each reorderDraft as pkg, index (pkg.name)}
        <div
          class="reorder-row"
          class:dragging={draggedPackageName === pkg.name}
          class:drag-target={dragOverPackageName === pkg.name}
          role="listitem"
          draggable="true"
          ondragstart={(event) => startDrag(event, pkg.name)}
          ondragover={(event) => dragOver(event, pkg.name)}
          ondragleave={() => {
            if (dragOverPackageName === pkg.name) dragOverPackageName = null;
          }}
          ondrop={(event) => dropPackage(event, pkg.name)}
          ondragend={endDrag}
        >
          <span class="order-number">{index + 1}</span>
          <button
            class="drag-handle"
            type="button"
            aria-label={`Drag ${pkg.name} to reorder. Use arrow keys for keyboard reordering.`}
            title="Drag to reorder"
            onkeydown={(event) => handleReorderKey(event, index)}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
              <circle cx="9" cy="5" r="1.35" />
              <circle cx="15" cy="5" r="1.35" />
              <circle cx="9" cy="12" r="1.35" />
              <circle cx="15" cy="12" r="1.35" />
              <circle cx="9" cy="19" r="1.35" />
              <circle cx="15" cy="19" r="1.35" />
            </svg>
          </button>
          <div class="reorder-identity">
            <strong>{pkg.name}</strong>
            {#if pkg.version}<span>{pkg.version}</span>{/if}
          </div>
        </div>
      {/each}
    </div>
  {/snippet}
</Dialog>

{#if toastVisible}
  <div class="toast" role="status" aria-live="polite">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12 4 4L19 6" /></svg>
    <span>{toastMessage}</span>
  </div>
{/if}

<style>
  .group-page { max-width: 1080px; margin: 0 auto; padding: 48px 24px 80px; }
  header { margin-bottom: 36px; }
  .label { color: var(--text-secondary); font-size: 12px; font-weight: 700; letter-spacing: .12em; }
  .title-row { display: flex; align-items: center; justify-content: space-between; gap: 20px; }
  h1 { margin: 8px 0; font-size: clamp(34px, 6vw, 64px); line-height: 1; }
  .group-description {
    max-width: 780px;
    margin: 14px 0 0;
    color: var(--foreground);
    font-size: clamp(17px, 2vw, 20px);
    line-height: 1.55;
  }
  .group-meta {
    display: flex;
    flex-wrap: wrap;
    gap: 8px 18px;
    margin-top: 16px;
    color: var(--muted-foreground);
    font-size: 13px;
    line-height: 1.4;
  }
  .group-meta span + span { position: relative; }
  .group-meta span + span::before {
    content: "";
    position: absolute;
    top: 50%;
    left: -10px;
    width: 3px;
    height: 3px;
    border-radius: 50%;
    background: currentColor;
  }
  .header-actions { display: flex; align-items: center; gap: 8px; }
  .menu-wrap { position: relative; }
  .more-button {
    display: inline-flex;
    width: 40px;
    height: 40px;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--background);
    color: var(--foreground);
    cursor: pointer;
  }
  .more-button:hover { background: var(--accent); }
  .action-menu {
    position: absolute;
    top: calc(100% + 7px);
    right: 0;
    z-index: 20;
    display: flex;
    width: 190px;
    flex-direction: column;
    padding: 5px;
    border: 1px solid var(--border);
    border-radius: 9px;
    background: var(--popover, var(--card));
    box-shadow: var(--dialog-shadow);
  }
  .action-menu button {
    padding: 9px 10px;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--foreground);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
  }
  .action-menu button:hover:not(:disabled) { background: var(--accent); }
  .action-menu button:disabled { opacity: 0.45; cursor: not-allowed; }
  .action-menu .danger-item { color: var(--destructive); }
  .management-panel {
    display: flex;
    flex-direction: column;
    gap: 26px;
    padding: 20px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: color-mix(in srgb, var(--muted) 18%, var(--card));
  }
  .edit-form { display: flex; flex-direction: column; gap: 22px; }
  .field, .search-field { display: flex; flex-direction: column; gap: 7px; }
  .field-label { color: var(--foreground); font-size: 14px; font-weight: 650; line-height: 1.3; }
  .field-hint { color: var(--muted-foreground); font-size: 12px; line-height: 1.45; }
  .field-control {
    width: 100%;
    padding: 11px 13px;
    border: 1px solid var(--border);
    border-radius: 8px;
    outline: none;
    background: var(--background);
    color: var(--foreground);
    font: inherit;
    transition: border-color 0.14s, box-shadow 0.14s;
  }
  .field-control::placeholder { color: var(--muted-foreground); }
  .field-control:hover { border-color: color-mix(in srgb, var(--foreground) 28%, var(--border)); }
  .field-control:focus { border-color: var(--ring); box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 25%, transparent); }
  .name-control { max-width: 520px; }
  .description-control { min-height: 132px; resize: vertical; line-height: 1.55; }
  .package-list {
    display: flex;
    flex-direction: column;
  }
  .empty { padding: 48px; border: 1px dashed var(--border); border-radius: 12px; color: var(--text-secondary); text-align: center; }
  .message { margin-top: 14px; }
  .error-message { color: var(--destructive); }
  .form-error { margin: 0; color: var(--destructive); font-size: 13px; }
  .package-picker { display: flex; flex-direction: column; gap: 14px; }
  .picker-summary { display: flex; justify-content: space-between; color: var(--muted-foreground); font-size: 12px; }
  .package-options {
    display: flex;
    max-height: min(52vh, 430px);
    flex-direction: column;
    overflow-y: auto;
    border: 1px solid var(--border);
    border-radius: 9px;
    background: var(--background);
  }
  .package-option {
    display: grid;
    grid-template-columns: 18px minmax(0, 1fr) auto;
    align-items: center;
    gap: 11px;
    min-height: 46px;
    padding: 9px 12px;
    border-bottom: 1px solid var(--border);
    cursor: pointer;
  }
  .package-option:last-child { border-bottom: 0; }
  .package-option:hover { background: color-mix(in srgb, var(--accent) 60%, transparent); }
  .package-option input { width: 16px; height: 16px; accent-color: var(--primary); }
  .option-name { overflow: hidden; color: var(--foreground); font-size: 14px; font-weight: 550; text-overflow: ellipsis; white-space: nowrap; }
  .included-label { color: var(--muted-foreground); font-size: 11px; }
  .picker-state { padding: 38px 18px; border: 1px dashed var(--border); border-radius: 9px; color: var(--muted-foreground); text-align: center; }

  .reorder-list {
    display: flex;
    max-height: min(58vh, 500px);
    flex-direction: column;
    overflow-y: auto;
    border: 1px solid var(--border);
    border-radius: 9px;
  }
  .reorder-row {
    display: grid;
    grid-template-columns: 28px 34px minmax(0, 1fr);
    align-items: center;
    gap: 12px;
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
    cursor: grab;
    transition: background 0.12s, opacity 0.12s, box-shadow 0.12s;
  }
  .reorder-row:last-child { border-bottom: 0; }
  .reorder-row:hover { background: color-mix(in srgb, var(--accent) 55%, transparent); }
  .reorder-row.dragging {
    opacity: 1;
    cursor: grabbing;
    background: var(--card);
    box-shadow: var(--dialog-shadow);
  }
  .reorder-row.drag-target {
    background: var(--background);
    box-shadow: inset 0 2px 0 var(--primary);
  }
  .order-number { color: var(--muted-foreground); font-size: 12px; text-align: center; }
  .reorder-identity { display: flex; min-width: 0; flex-direction: column; gap: 2px; }
  .reorder-identity strong { overflow: hidden; color: var(--foreground); font-size: 14px; text-overflow: ellipsis; white-space: nowrap; }
  .reorder-identity span { color: var(--muted-foreground); font-family: var(--pub-code-font-family); font-size: 11px; }
  .drag-handle {
    display: inline-flex;
    width: 32px;
    height: 32px;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--muted-foreground);
    cursor: grab;
    touch-action: none;
  }
  .drag-handle:hover { color: var(--foreground); background: var(--accent); }
  .drag-handle:focus-visible { outline: 2px solid var(--ring); outline-offset: 1px; }
  .drag-handle:active { cursor: grabbing; }
  .toast {
    position: fixed;
    right: 22px;
    bottom: 22px;
    z-index: calc(var(--dialog-z) + 10);
    display: flex;
    align-items: center;
    gap: 10px;
    max-width: min(360px, calc(100vw - 32px));
    padding: 12px 15px;
    border: 1px solid color-mix(in srgb, var(--primary) 38%, var(--border));
    border-radius: 9px;
    background: var(--card);
    color: var(--foreground);
    box-shadow: var(--dialog-shadow);
    font-size: 14px;
  }
  .toast svg { color: var(--primary); flex-shrink: 0; }

  @media (max-width: 600px) {
    .title-row { align-items: flex-start; flex-direction: column; }
    .header-actions { width: 100%; }
    .reorder-row { grid-template-columns: 22px 34px minmax(0, 1fr); }
    .management-panel { padding: 16px; }
  }
</style>
