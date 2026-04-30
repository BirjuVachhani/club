<script lang="ts">
  import TagBadge from './TagBadge.svelte';

  interface Tag {
    label: string;
    kind?: 'sdk' | 'platform' | 'status';
  }

  interface Props {
    tags: Tag[];
  }

  let { tags }: Props = $props();
</script>

<div class="relative overflow-hidden">
  <div class="pointer-events-none absolute inset-y-0 left-0 z-1 w-6 bg-gradient-to-r from-[var(--card)] to-transparent"></div>
  <div class="pointer-events-none absolute inset-y-0 right-0 z-1 w-6 bg-gradient-to-l from-[var(--card)] to-transparent"></div>
  <div class="flex gap-1.5 overflow-x-auto px-6 py-0.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
    {#each tags as tag}
      <TagBadge label={tag.label} kind={tag.kind} />
    {/each}
  </div>
</div>
