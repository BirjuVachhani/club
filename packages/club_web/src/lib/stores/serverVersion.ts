import { writable } from 'svelte/store';

/**
 * Running server version, displayed in the footer for everyone (signed
 * out included). Hydrated once from `/api/v1/version` in the root
 * layout load — the value is constant for the life of the process so
 * we don't need to refetch.
 */
export const serverVersion = writable<string | null>(null);
