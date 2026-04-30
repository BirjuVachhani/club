import { writable } from 'svelte/store';
import { browser } from '$app/environment';

export type Theme = 'light' | 'dark';

function createThemeStore() {
  let initial: Theme = 'light';

  if (browser) {
    const stored = localStorage.getItem('club_theme') as Theme | null;
    if (stored === 'light' || stored === 'dark') {
      initial = stored;
    }
  }

  const { subscribe, set } = writable<Theme>(initial);

  function applyTheme(theme: Theme) {
    if (!browser) return;
    const root = document.documentElement;
    root.classList.remove('light-theme', 'dark-theme');
    root.classList.add(`${theme}-theme`);
    document.body.classList.remove('light-theme', 'dark-theme');
    document.body.classList.add(`${theme}-theme`);
    localStorage.setItem('club_theme', theme);
  }

  // Apply on init.
  if (browser) {
    applyTheme(initial);
  }

  return {
    subscribe,

    setTheme(theme: Theme) {
      set(theme);
      applyTheme(theme);
    },

    toggle() {
      let current: Theme = 'light';
      subscribe((v) => (current = v))();
      const next: Theme = current === 'light' ? 'dark' : 'light';
      set(next);
      applyTheme(next);
    }
  };
}

export const theme = createThemeStore();
