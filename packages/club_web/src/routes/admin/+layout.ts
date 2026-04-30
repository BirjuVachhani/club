import { browser } from '$app/environment';
import { redirect } from '@sveltejs/kit';
import { get } from 'svelte/store';
import { auth, roleIsAtLeast } from '$lib/stores/auth';
import type { LayoutLoad } from './$types';

/**
 * Client-side gate for every `/admin/*` route. SvelteKit runs nested
 * layout loads in parallel with the parent by default, so we `await
 * parent()` to guarantee the root layout has hydrated the auth store
 * from `/api/auth/me` before we inspect it. The server re-checks
 * every request — this is UX polish, not a security boundary.
 */
export const load: LayoutLoad = async ({ url, parent }) => {
  if (!browser) return {};
  await parent();
  const { user } = get(auth);
  if (!user) {
    throw redirect(
      302,
      `/login?redirect=${encodeURIComponent(url.pathname + url.search)}`
    );
  }
  if (!roleIsAtLeast(user.role, 'admin')) {
    throw redirect(302, '/');
  }
  return {};
};
