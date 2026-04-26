<script lang="ts">
  import Badge from '$lib/components/ui/Badge.svelte';

  interface Props {
    label: string;
    kind?: 'sdk' | 'platform' | 'status';
  }

  let { label, kind = 'sdk' }: Props = $props();

  const variant = $derived(kind === 'status' ? 'success' : kind === 'platform' ? 'outline' : 'secondary');
</script>

<Badge {variant} class="whitespace-nowrap">
  {label}
</Badge>
