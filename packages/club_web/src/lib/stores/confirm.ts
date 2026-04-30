import { writable } from 'svelte/store';

export interface ConfirmOptions {
  title: string;
  description?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  confirmVariant?: 'default' | 'destructive';
  /** If set, user must type this exact string before Confirm enables. */
  confirmText?: string;
}

export interface ConfirmState extends ConfirmOptions {
  open: boolean;
  resolve: (result: boolean) => void;
}

export const confirmState = writable<ConfirmState | null>(null);

/**
 * Promise-based replacement for window.confirm that renders the
 * in-app Dialog component. Host is mounted once in the root layout.
 */
export function confirmDialog(options: ConfirmOptions): Promise<boolean> {
  return new Promise((resolve) => {
    confirmState.set({
      confirmVariant: 'destructive',
      ...options,
      open: true,
      resolve
    });
  });
}
