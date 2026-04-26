/**
 * Debounced text signal for search inputs. Use like:
 *
 *   const search = createDebouncedSignal();
 *   // bind:value={search.raw}, oninput={e => search.set(e.currentTarget.value)}
 *   $effect(() => {
 *     const q = search.debounced;
 *     load(q);
 *   });
 *
 * Kept intentionally small: no cancel, no leading-edge mode — every
 * consumer needs "type, wait, fire".
 */
export interface DebouncedSignal {
  readonly raw: string;
  readonly debounced: string;
  set(v: string): void;
}

export function createDebouncedSignal(delayMs = 250): DebouncedSignal {
  let raw = $state('');
  let debounced = $state('');
  let timer: ReturnType<typeof setTimeout> | undefined;

  return {
    get raw() {
      return raw;
    },
    get debounced() {
      return debounced;
    },
    set(v: string) {
      raw = v;
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => (debounced = v), delayMs);
    },
  };
}
