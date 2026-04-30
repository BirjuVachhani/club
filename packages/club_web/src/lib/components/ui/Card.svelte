<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils/cn';

  interface Props {
    children?: Snippet;
    class?: string;
  }

  let { children, class: className = '' }: Props = $props();
</script>

<div class={cn('rounded-xl border border-[var(--border)] bg-[var(--card)] text-[var(--card-foreground)] shadow-xs', className)}>
  {@render children?.()}
</div>
