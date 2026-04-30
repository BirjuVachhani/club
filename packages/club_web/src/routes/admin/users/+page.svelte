<script lang="ts">
  import { api, ApiError } from '$lib/api/client';
  import { auth, type UserRole } from '$lib/stores/auth';
  import { confirmDialog } from '$lib/stores/confirm';

  type Mode = 'password' | 'invite';

  interface AdminUser {
    userId: string;
    email: string;
    displayName: string;
    role: UserRole;
    isActive: boolean;
    mustChangePassword: boolean;
    createdAt: string;
  }

  const ROLES: UserRole[] = ['owner', 'admin', 'member', 'viewer'];

  let users = $state<AdminUser[]>([]);
  let totalCount = $state(0);
  let nextPage = $state<string | null>(null);
  let loading = $state(true);
  let message = $state('');
  let messageTone: 'info' | 'error' | 'success' = $state('info');

  let emailFilter = $state('');
  let debouncedEmail = $state('');
  let emailTimer: ReturnType<typeof setTimeout> | undefined;
  function onEmailInput() {
    if (emailTimer) clearTimeout(emailTimer);
    emailTimer = setTimeout(() => {
      debouncedEmail = emailFilter;
    }, 300);
  }

  // Who am I? The "can't touch the owner / can't touch yourself" rules
  // are mirrored client-side as UI polish.
  let me = $state<{ id: string; role: UserRole | undefined } | null>(null);
  auth.subscribe((s) => {
    me = s.user ? { id: s.user.id, role: s.user.role } : null;
  });

  // ── Create-user form state ──────────────────────────────────
  let showCreateForm = $state(false);
  let newEmail = $state('');
  let newName = $state('');
  let newRole = $state<UserRole>('viewer');
  let newMode = $state<Mode>('password');

  // After creation we display the one-time password or invite URL.
  let createResult = $state<
    | { mode: 'password'; email: string; password: string }
    | { mode: 'invite'; email: string; url: string; expiresInHours: number }
    | null
  >(null);

  // ── Edit-user state (role / active toggle) ──────────────────
  let editingUserId = $state<string | null>(null);
  let editDraft = $state<{ role: UserRole; isActive: boolean } | null>(null);

  // ── Reset-password result panel ─────────────────────────────
  let resetResult = $state<{ email: string; password: string } | null>(null);

  $effect(() => {
    // Re-load whenever the debounced email filter changes.
    const _ = debouncedEmail;
    loadUsers();
  });

  async function loadUsers(page?: string) {
    loading = true;
    try {
      const qs = new URLSearchParams();
      if (debouncedEmail) qs.set('email', debouncedEmail);
      if (page) qs.set('page', page);
      const data = await api.get<{
        users: AdminUser[];
        totalCount: number;
        nextPageToken?: string | null;
      }>(`/api/admin/users${qs.toString() ? `?${qs}` : ''}`);
      if (page) {
        users = [...users, ...(data.users ?? [])];
      } else {
        users = data.users ?? [];
      }
      totalCount = data.totalCount ?? users.length;
      nextPage = data.nextPageToken ?? null;
    } catch {
      setMessage('Failed to load users.', 'error');
    }
    loading = false;
  }

  async function loadMore() {
    if (nextPage) await loadUsers(nextPage);
  }

  function setMessage(text: string, tone: typeof messageTone = 'info') {
    message = text;
    messageTone = tone;
  }

  async function createUser() {
    if (!newEmail.trim() || !newName.trim()) return;
    try {
      const body = await api.post<any>('/api/admin/users', {
        email: newEmail.trim(),
        displayName: newName.trim(),
        role: newRole,
        mode: newMode
      });
      if (newMode === 'password') {
        createResult = {
          mode: 'password',
          email: body.email,
          password: body.generatedPassword
        };
      } else {
        createResult = {
          mode: 'invite',
          email: body.email,
          url: body.inviteUrl,
          expiresInHours: body.inviteExpiresInHours
        };
      }
      newEmail = '';
      newName = '';
      newRole = 'viewer';
      showCreateForm = false;
      await loadUsers();
    } catch (e) {
      setMessage(errorMessage(e, 'Failed to create user.'), 'error');
    }
  }

  function startEdit(u: AdminUser) {
    editingUserId = u.userId;
    editDraft = { role: u.role, isActive: u.isActive };
  }

  function cancelEdit() {
    editingUserId = null;
    editDraft = null;
  }

  async function saveEdit(u: AdminUser) {
    if (!editDraft) return;
    try {
      await api.put(`/api/admin/users/${u.userId}`, {
        role: editDraft.role,
        isActive: editDraft.isActive
      });
      cancelEdit();
      setMessage(`Updated ${u.email}.`, 'success');
      await loadUsers();
    } catch (e) {
      setMessage(errorMessage(e, 'Failed to update user.'), 'error');
    }
  }

  async function resetPassword(u: AdminUser) {
    const ok = await confirmDialog({
      title: `Reset password for ${u.email}?`,
      description: 'A new random password will be generated.',
      confirmLabel: 'Reset password',
      confirmVariant: 'destructive'
    });
    if (!ok) return;
    try {
      const body = await api.post<any>(
        `/api/admin/users/${u.userId}/reset-password`,
        {}
      );
      resetResult = { email: u.email, password: body.generatedPassword };
    } catch (e) {
      setMessage(errorMessage(e, 'Failed to reset password.'), 'error');
    }
  }

  async function deleteUser(u: AdminUser) {
    const ok = await confirmDialog({
      title: `Delete ${u.email}?`,
      description: 'This cannot be undone.',
      confirmLabel: 'Delete',
      confirmVariant: 'destructive',
      confirmText: u.email
    });
    if (!ok) return;
    try {
      await api.delete(`/api/admin/users/${u.userId}`);
      setMessage(`Deleted ${u.email}.`, 'success');
      await loadUsers();
    } catch (e) {
      setMessage(errorMessage(e, 'Failed to delete user.'), 'error');
    }
  }

  // Client-side mirror of Permissions.canModifyUser — used to grey out
  // row actions the server would reject anyway.
  function canActOn(u: AdminUser): boolean {
    if (!me?.role) return false;
    if (me.id === u.userId) return false;
    if (u.role === 'owner') return me.role === 'owner';
    return me.role === 'owner' || me.role === 'admin';
  }

  // Copy helper with a quick visual hint.
  let copyingKey = $state<string | null>(null);
  async function copy(key: string, value: string) {
    try {
      await navigator.clipboard.writeText(value);
      copyingKey = key;
      setTimeout(() => {
        if (copyingKey === key) copyingKey = null;
      }, 1200);
    } catch {
      // Silently fail.
    }
  }

  function errorMessage(e: unknown, fallback: string): string {
    if (e instanceof ApiError) {
      const body = e.body as { error?: { message?: string } } | undefined;
      return body?.error?.message ?? fallback;
    }
    return fallback;
  }
</script>

<svelte:head><title>Users · Admin | CLUB</title></svelte:head>

<div class="admin-users">
  <div class="header-row">
    <h1>User Management</h1>
    <button class="primary" onclick={() => { showCreateForm = !showCreateForm; createResult = null; }}>
      {showCreateForm ? 'Cancel' : 'Create user'}
    </button>
  </div>

  {#if message}
    <div class="message message-{messageTone}">{message}</div>
  {/if}

  <div class="filter-row">
    <input
      type="search"
      placeholder="Filter by email..."
      bind:value={emailFilter}
      oninput={onEmailInput}
      class="email-filter"
    />
    <span class="count-label">
      Showing {users.length} of {totalCount}
    </span>
  </div>

  <!-- Create-user form -->
  {#if showCreateForm}
    <form class="create-form" onsubmit={(e) => { e.preventDefault(); createUser(); }}>
      <div class="field">
        <label for="newEmail">Email</label>
        <input id="newEmail" type="email" bind:value={newEmail} required />
      </div>
      <div class="field">
        <label for="newName">Display name</label>
        <input id="newName" type="text" bind:value={newName} required />
      </div>
      <div class="field">
        <label for="newRole">Role</label>
        <select id="newRole" bind:value={newRole}>
          {#each ROLES as r}
            <!-- Only owners can create owners (handled server-side too). -->
            {#if r !== 'owner' || me?.role === 'owner'}
              <option value={r}>{r}</option>
            {/if}
          {/each}
        </select>
      </div>
      <fieldset class="field mode-group">
        <legend>Initial credential</legend>
        <div class="mode-choices">
          <label class="mode-choice">
            <input type="radio" name="mode" value="password" bind:group={newMode} />
            <span>Generate password</span>
            <small>Shown once in this UI. User forced to reset on first login.</small>
          </label>
          <label class="mode-choice">
            <input type="radio" name="mode" value="invite" bind:group={newMode} />
            <span>Invite link</span>
            <small>One-time link. User sets their own password.</small>
          </label>
        </div>
      </fieldset>
      <div class="form-actions">
        <button type="submit" class="primary">Create</button>
      </div>
    </form>
  {/if}

  <!-- Create-user result panel — shown exactly once -->
  {#if createResult}
    <div class="result-panel">
      <div class="result-header">
        <strong>{createResult.email}</strong> created.
        <button class="close" onclick={() => createResult = null}>✕</button>
      </div>
      {#if createResult.mode === 'password'}
        <p class="result-note">
          This password will not be shown again — copy it and share with the
          user through a secure channel. They'll be forced to pick a new
          password on first login.
        </p>
        <div class="secret-row">
          <code>{createResult.password}</code>
          <button onclick={() => copy('create-pw', createResult!.mode === 'password' ? createResult!.password : '')}>
            {copyingKey === 'create-pw' ? 'Copied' : 'Copy'}
          </button>
        </div>
      {:else}
        <p class="result-note">
          One-time invite link — expires in {createResult.expiresInHours}h.
          Share with the user; they'll set their own password.
        </p>
        <div class="secret-row">
          <code>{createResult.url}</code>
          <button onclick={() => copy('create-url', createResult!.mode === 'invite' ? createResult!.url : '')}>
            {copyingKey === 'create-url' ? 'Copied' : 'Copy'}
          </button>
        </div>
      {/if}
    </div>
  {/if}

  <!-- Reset-password result panel -->
  {#if resetResult}
    <div class="result-panel">
      <div class="result-header">
        Password reset for <strong>{resetResult.email}</strong>.
        <button class="close" onclick={() => resetResult = null}>✕</button>
      </div>
      <p class="result-note">
        Shown once. User must change on next login.
      </p>
      <div class="secret-row">
        <code>{resetResult.password}</code>
        <button onclick={() => copy('reset-pw', resetResult!.password)}>
          {copyingKey === 'reset-pw' ? 'Copied' : 'Copy'}
        </button>
      </div>
    </div>
  {/if}

  <!-- Users table -->
  {#if loading}
    <p>Loading...</p>
  {:else}
    <div class="table-scroll">
    <table>
      <thead>
        <tr>
          <th>Email</th>
          <th>Name</th>
          <th>Role</th>
          <th>Active</th>
          <th>Created</th>
          <th class="actions-col">Actions</th>
        </tr>
      </thead>
      <tbody>
        {#each users as u}
          <tr class:inactive={!u.isActive}>
            <td>
              {u.email}
              {#if u.mustChangePassword}
                <span class="pill" title="User must change password on next login">
                  pw reset
                </span>
              {/if}
            </td>
            <td>{u.displayName}</td>
            <td>
              {#if editingUserId === u.userId && editDraft}
                <select bind:value={editDraft.role}>
                  {#each ROLES as r}
                    {#if r !== 'owner' || me?.role === 'owner'}
                      <option value={r}>{r}</option>
                    {/if}
                  {/each}
                </select>
              {:else}
                <span class="role-badge role-{u.role}">{u.role}</span>
              {/if}
            </td>
            <td>
              {#if editingUserId === u.userId && editDraft}
                <input type="checkbox" bind:checked={editDraft.isActive} />
              {:else}
                {u.isActive ? 'Yes' : 'No'}
              {/if}
            </td>
            <td>{new Date(u.createdAt).toLocaleDateString()}</td>
            <td class="actions-col">
              {#if editingUserId === u.userId}
                <button class="mini primary" onclick={() => saveEdit(u)}>Save</button>
                <button class="mini" onclick={cancelEdit}>Cancel</button>
              {:else if canActOn(u)}
                <button class="mini" onclick={() => startEdit(u)}>Edit</button>
                <button class="mini" onclick={() => resetPassword(u)}>Reset pw</button>
                <button class="mini danger" onclick={() => deleteUser(u)}>Delete</button>
              {:else}
                <span class="muted">—</span>
              {/if}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
    </div>
    {#if nextPage}
      <div class="more">
        <button class="secondary" onclick={loadMore} disabled={loading}>
          {loading ? 'Loading...' : 'Load more'}
        </button>
      </div>
    {/if}
  {/if}
</div>

<style>
  .filter-row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.75rem 1rem;
    margin-bottom: 1rem;
  }
  .email-filter {
    flex: 1 1 14rem;
    max-width: 20rem;
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--foreground);
    font: inherit;
  }
  .email-filter:focus {
    outline: none;
    border-color: var(--ring);
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--ring) 35%, transparent);
  }
  .count-label {
    color: var(--muted-foreground);
    font-size: 0.8125rem;
  }
  .more {
    display: flex;
    justify-content: center;
    padding: 1rem 0;
  }
  .admin-users {
    max-width: 1100px;
    margin: 0 auto;
    padding: 1rem 0;
  }
  .header-row {
    display: flex;
    flex-wrap: wrap;
    justify-content: space-between;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 1rem;
  }
  h1 {
    margin: 0;
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--foreground);
  }

  /* Message banners */
  .message {
    padding: 0.75rem 1rem;
    border-radius: 8px;
    margin-bottom: 1rem;
    font-size: 0.875rem;
  }
  .message-info { background: var(--muted); color: var(--foreground); }
  .message-success {
    background: color-mix(in srgb, var(--success) 15%, var(--card));
    color: var(--success);
    border: 1px solid color-mix(in srgb, var(--success) 40%, transparent);
  }
  .message-error {
    background: color-mix(in srgb, var(--destructive) 15%, var(--card));
    color: var(--destructive);
    border: 1px solid color-mix(in srgb, var(--destructive) 40%, transparent);
  }

  /* Create form */
  .create-form {
    display: grid;
    grid-template-columns: 1fr;
    gap: 0.75rem 1rem;
    margin-bottom: 1.5rem;
    padding: 1rem;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--card);
  }
  @media (min-width: 768px) {
    .create-form {
      grid-template-columns: repeat(3, 1fr);
      padding: 1.25rem;
    }
  }
  .field { display: flex; flex-direction: column; gap: 0.35rem; }
  .field label { font-size: 0.75rem; font-weight: 500; color: var(--muted-foreground); }
  .field input,
  .field select {
    padding: 0.5rem 0.625rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--background);
    color: var(--foreground);
    font-size: 0.875rem;
  }
  .mode-group { grid-column: 1 / -1; }
  .mode-choices { display: grid; grid-template-columns: 1fr; gap: 0.75rem; margin-top: 0.25rem; }
  @media (min-width: 640px) {
    .mode-choices { grid-template-columns: 1fr 1fr; }
  }
  .mode-choice {
    display: grid;
    grid-template-columns: auto 1fr;
    grid-template-rows: auto auto;
    column-gap: 0.5rem;
    padding: 0.75rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    cursor: pointer;
  }
  .mode-choice input { grid-row: span 2; align-self: center; }
  .mode-choice span { font-size: 0.875rem; color: var(--foreground); font-weight: 500; }
  .mode-choice small {
    grid-column: 2;
    font-size: 0.75rem;
    color: var(--muted-foreground);
    line-height: 1.4;
  }
  .form-actions { grid-column: 1 / -1; }

  /* Secret display */
  .result-panel {
    margin-bottom: 1rem;
    padding: 1rem;
    border: 1px solid var(--primary);
    border-radius: 10px;
    background: color-mix(in srgb, var(--primary) 5%, var(--card));
  }
  .result-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.5rem;
    font-size: 0.9375rem;
  }
  .result-header .close {
    margin-left: auto;
    background: none;
    border: none;
    cursor: pointer;
    font-size: 0.875rem;
    color: var(--muted-foreground);
  }
  .result-note {
    margin: 0 0 0.75rem;
    font-size: 0.8125rem;
    color: var(--muted-foreground);
  }
  .secret-row {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    align-items: center;
  }
  .secret-row code {
    flex: 1 1 12rem;
    min-width: 0;
    padding: 0.5rem 0.75rem;
    background: var(--muted);
    border: 1px solid var(--border);
    border-radius: 6px;
    font-family: var(--pub-code-font-family);
    font-size: 0.8125rem;
    overflow-x: auto;
    white-space: nowrap;
  }

  /* Table — horizontal scroll on narrow screens */
  .table-scroll {
    width: 100%;
    overflow-x: auto;
    -webkit-overflow-scrolling: touch;
    margin: 0 -0.5rem;
    padding: 0 0.5rem;
  }
  table {
    width: 100%;
    min-width: 640px;
    border-collapse: collapse;
    font-size: 0.875rem;
  }
  th, td {
    text-align: left;
    padding: 0.75rem;
    border-bottom: 1px solid var(--border);
  }
  th {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--muted-foreground);
    font-weight: 600;
  }
  tr.inactive { opacity: 0.55; }
  .actions-col { text-align: right; white-space: nowrap; }
  .pill {
    display: inline-block;
    margin-left: 0.5rem;
    padding: 1px 6px;
    font-size: 0.6875rem;
    background: var(--muted);
    color: var(--muted-foreground);
    border-radius: 4px;
  }
  .muted { color: var(--muted-foreground); }

  .role-badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 0.75rem;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .role-owner { background: var(--primary); color: var(--primary-foreground); }
  .role-admin {
    background: color-mix(in srgb, var(--primary) 20%, transparent);
    color: var(--primary);
  }
  .role-member {
    background: var(--muted);
    color: var(--foreground);
  }
  .role-viewer {
    background: var(--muted);
    color: var(--muted-foreground);
  }

  /* Buttons */
  button {
    padding: 0.5rem 0.875rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--card);
    color: var(--foreground);
    font-size: 0.8125rem;
    font-family: inherit;
    cursor: pointer;
  }
  button:hover { background: var(--accent); }
  button.primary {
    background: var(--primary);
    color: var(--primary-foreground);
    border-color: var(--primary);
  }
  button.primary:hover { opacity: 0.9; }
  button.mini { padding: 0.25rem 0.625rem; font-size: 0.75rem; margin-left: 0.25rem; }
  button.danger { color: var(--destructive); border-color: var(--destructive); }
</style>
