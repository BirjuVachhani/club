<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils/cn';

  interface Props {
    children?: Snippet;
    class?: string;
  }

  let { children, class: className = '' }: Props = $props();
</script>

<div class={cn('rounded-lg border border-[var(--border)] bg-[var(--card)] px-4 py-3 text-sm text-[var(--card-foreground)]', className)}>
  {@render children?.()}
</div>
