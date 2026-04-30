<script lang="ts">
  import { cva, type VariantProps } from 'class-variance-authority';
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils/cn';

  const badgeVariants = cva(
    'inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold transition-colors',
    {
      variants: {
        variant: {
          default: 'border-transparent bg-[var(--primary)] text-[var(--primary-foreground)]',
          secondary: 'border-transparent bg-[var(--secondary)] text-[var(--secondary-foreground)]',
          outline: 'border-[var(--border)] bg-transparent text-[var(--foreground)]',
          success: 'border-transparent bg-[var(--success)] text-white',
          muted: 'border-transparent bg-[var(--muted)] text-[var(--muted-foreground)]'
        }
      },
      defaultVariants: {
        variant: 'secondary'
      }
    }
  );

  interface Props extends VariantProps<typeof badgeVariants> {
    children?: Snippet;
    class?: string;
  }

  let {
    children,
    class: className = '',
    variant = 'secondary'
  }: Props = $props();
</script>

<span class={cn(badgeVariants({ variant }), className)}>
  {@render children?.()}
</span>
