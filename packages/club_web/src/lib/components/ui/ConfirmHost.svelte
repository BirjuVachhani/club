<script lang="ts">
  import Dialog from './Dialog.svelte';
  import { confirmState, type ConfirmState } from '$lib/stores/confirm';

  let state = $state<ConfirmState | null>(null);

  $effect(() => {
    const unsub = confirmState.subscribe((s) => {
      state = s;
    });
    return unsub;
  });

  let open = $derived(!!state?.open);

  function handleConfirm() {
    state?.resolve(true);
    confirmState.set(null);
  }

  function handleCancel() {
    state?.resolve(false);
    confirmState.set(null);
  }
</script>

{#if state}
  <Dialog
    {open}
    title={state.title}
    description={state.description}
    confirmLabel={state.confirmLabel ?? 'Confirm'}
    cancelLabel={state.cancelLabel ?? 'Cancel'}
    confirmVariant={state.confirmVariant ?? 'destructive'}
    confirmText={state.confirmText}
    onConfirm={handleConfirm}
    onCancel={handleCancel}
  />
{/if}
