<script lang="ts">
  import Alert from '$lib/components/ui/Alert.svelte';
  import Button from '$lib/components/ui/Button.svelte';
  import Card from '$lib/components/ui/Card.svelte';
  import Input from '$lib/components/ui/Input.svelte';
  import { api, ApiError } from '$lib/api/client';
  import { auth } from '$lib/stores/auth';
  import { get } from 'svelte/store';
  import type { User } from '$lib/stores/auth';

  const initial = get(auth).user;
  let displayName = $state(initial?.name ?? '');
  let error = $state('');
  let success = $state('');
  let saving = $state(false);

  // Avatar state
  let avatarUrl = $state(initial?.avatarUrl ?? null);
  let avatarUploading = $state(false);
  let avatarError = $state('');
  let fileInput: HTMLInputElement;

  const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5 MB

  function getInitials(name: string): string {
    return name
      .split(/\s+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0].toUpperCase())
      .join('');
  }

  async function save(event: Event) {
    event.preventDefault();
    error = '';
    success = '';

    const trimmed = displayName.trim();
    if (!trimmed) {
      error = 'Name is required.';
      return;
    }

    saving = true;
    try {
      const updated = await api.patch<User & { displayName: string }>(
        '/api/auth/profile',
        { displayName: trimmed }
      );
      const current = get(auth).user;
      if (current) {
        auth.updateUser({ ...current, name: updated.displayName });
      }
      success = 'Profile updated.';
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { error?: { message?: string }; message?: string } | undefined;
        error = body?.error?.message ?? body?.message ?? 'Failed to update profile.';
      } else {
        error = 'Failed to update profile.';
      }
    } finally {
      saving = false;
    }
  }

  function triggerFileSelect() {
    fileInput?.click();
  }

  async function handleFileSelect(event: Event) {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;

    avatarError = '';

    // Validate file type
    const allowed = ['image/jpeg', 'image/png', 'image/webp'];
    if (!allowed.includes(file.type)) {
      avatarError = 'Unsupported format. Please use JPEG, PNG, or WebP.';
      input.value = '';
      return;
    }

    // Validate file size
    if (file.size > MAX_FILE_SIZE) {
      avatarError = 'File too large. Maximum size is 5 MB.';
      input.value = '';
      return;
    }

    avatarUploading = true;
    try {
      const formData = new FormData();
      formData.append('file', file);

      const result = await api.upload<{ avatarUrl: string }>('/api/auth/avatar', formData);
      avatarUrl = result.avatarUrl;

      const current = get(auth).user;
      if (current) {
        auth.updateUser({ ...current, avatarUrl: result.avatarUrl });
      }
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { error?: { message?: string }; message?: string } | undefined;
        avatarError = body?.error?.message ?? body?.message ?? 'Failed to upload avatar.';
      } else {
        avatarError = 'Failed to upload avatar.';
      }
    } finally {
      avatarUploading = false;
      input.value = '';
    }
  }

  async function removeAvatar() {
    avatarError = '';
    avatarUploading = true;
    try {
      await api.delete('/api/auth/avatar');
      avatarUrl = null;

      const current = get(auth).user;
      if (current) {
        auth.updateUser({ ...current, avatarUrl: null });
      }
    } catch (err) {
      if (err instanceof ApiError) {
        const body = err.body as { error?: { message?: string }; message?: string } | undefined;
        avatarError = body?.error?.message ?? body?.message ?? 'Failed to remove avatar.';
      } else {
        avatarError = 'Failed to remove avatar.';
      }
    } finally {
      avatarUploading = false;
    }
  }
</script>

<div class="space-y-6">
  <div>
    <h2 class="mb-1 text-2xl font-semibold tracking-tight">Profile</h2>
    <p class="m-0 text-sm text-[var(--muted-foreground)]">Update how your name appears across CLUB.</p>
  </div>

  {#if error}
    <Alert class="border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_10%,var(--card))] text-[var(--destructive)]">
      {error}
    </Alert>
  {/if}

  {#if success}
    <Alert class="border-[var(--success)]/30 bg-[color:color-mix(in_srgb,var(--success)_10%,var(--card))] text-[var(--success)]">
      {success}
    </Alert>
  {/if}

  <!--
    Single container for profile picture + name. The two fields are one
    logical "edit my profile" concern, so we separate them with a hairline
    divider rather than splitting into two cards.
  -->
  <Card class="max-w-2xl p-6">
    <form class="divide-y divide-[var(--border)]" onsubmit={save}>
      <!-- Profile picture row -->
      <section class="space-y-3 pb-6">
        <div>
          <h3 class="m-0 text-sm font-medium">Profile picture</h3>
          <p class="m-0 mt-0.5 text-xs text-[var(--muted-foreground)]">
            JPEG, PNG, or WebP. Max 5 MB.
          </p>
        </div>

        {#if avatarError}
          <Alert class="border-[var(--destructive)]/30 bg-[color:color-mix(in_srgb,var(--destructive)_10%,var(--card))] text-[var(--destructive)]">
            {avatarError}
          </Alert>
        {/if}

        <div class="flex items-center gap-5">
          <!-- Avatar preview -->
          <div class="relative h-20 w-20 shrink-0 overflow-hidden rounded-full bg-[var(--muted)]">
            {#if avatarUrl}
              <img
                src={avatarUrl}
                alt="Profile avatar"
                class="h-full w-full object-cover"
              />
            {:else}
              <div class="flex h-full w-full items-center justify-center text-xl font-semibold text-[var(--muted-foreground)]">
                {getInitials(displayName || initial?.email || '?')}
              </div>
            {/if}
            {#if avatarUploading}
              <div class="absolute inset-0 flex items-center justify-center bg-black/40 text-white text-xs">
                ...
              </div>
            {/if}
          </div>

          <!-- Upload / remove buttons -->
          <div class="flex flex-wrap gap-2">
            <input
              bind:this={fileInput}
              type="file"
              accept="image/jpeg,image/png,image/webp"
              class="hidden"
              onchange={handleFileSelect}
            />
            <Button
              variant="outline"
              size="sm"
              disabled={avatarUploading}
              onclick={triggerFileSelect}
            >
              {avatarUploading ? 'Uploading...' : 'Upload picture'}
            </Button>
            {#if avatarUrl}
              <Button
                variant="ghost"
                size="sm"
                class="text-xs text-[var(--destructive)] hover:bg-[color-mix(in_srgb,var(--destructive)_12%,transparent)] hover:text-[var(--destructive)]"
                disabled={avatarUploading}
                onclick={removeAvatar}
              >
                Remove
              </Button>
            {/if}
          </div>
        </div>
      </section>

      <!-- Name row -->
      <section class="space-y-2 pt-6">
        <label for="display-name" class="block text-sm font-medium">Name</label>
        <Input id="display-name" type="text" bind:value={displayName} autocomplete="name" />
      </section>

      <!-- Single footer save button applies to both the name change and
           any pending avatar state (avatar already autosaves on upload, so
           Save only persists the name). -->
      <div class="flex justify-end pt-6">
        <Button type="submit" disabled={saving}>
          {saving ? 'Saving...' : 'Save'}
        </Button>
      </div>
    </form>
  </Card>
</div>
