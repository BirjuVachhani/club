<script lang="ts">
  import { cva, type VariantProps } from 'class-variance-authority';
  import type { Snippet } from 'svelte';
  import type { HTMLButtonAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils/cn';

  const buttonVariants = cva(
    'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 disabled:pointer-events-none disabled:opacity-50',
    {
      variants: {
        variant: {
          default: 'bg-[var(--primary)] text-[var(--primary-foreground)] shadow-sm hover:brightness-110',
          secondary: 'border border-[var(--border)] bg-[var(--secondary)] text-[var(--secondary-foreground)] hover:bg-[var(--accent)] hover:text-[var(--accent-foreground)]',
          outline: 'border border-[var(--border)] bg-[var(--background)] text-[var(--foreground)] hover:bg-[var(--accent)] hover:text-[var(--accent-foreground)]',
          ghost: 'text-[var(--muted-foreground)] hover:bg-[var(--accent)] hover:text-[var(--accent-foreground)]',
          destructive: 'bg-[var(--destructive)] text-[var(--destructive-foreground)] shadow-sm hover:brightness-105'
        },
        size: {
          default: 'h-10 px-4 py-2',
          sm: 'h-9 px-3',
          lg: 'h-11 px-6',
          icon: 'h-10 w-10 p-0'
        }
      },
      defaultVariants: {
        variant: 'default',
        size: 'default'
      }
    }
  );

  interface Props extends HTMLButtonAttributes, VariantProps<typeof buttonVariants> {
    children?: Snippet;
    class?: string;
  }

  let {
    children,
    class: className = '',
    variant = 'default',
    size = 'default',
    type = 'button',
    ...rest
  }: Props = $props();
</script>

<button
  {...rest}
  {type}
  class={cn(buttonVariants({ variant, size }), className)}
>
  {@render children?.()}
</button>
