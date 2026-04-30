import { browser } from '$app/environment';
import { redirect } from '@sveltejs/kit';
import { auth, type User } from '$lib/stores/auth';
import type { LayoutLoad } from './$types';

export const ssr = false;
export const prerender = false;

/**
 * Routes that don't require authentication. Visited paths that start
 * with any of these bypass the auth + must-change-password guards.
 */
const PUBLIC_PATH_PREFIXES = [
  '/login',
  '/setup',
  '/signup',
  '/invite',
  '/auth/cli',
  '/oauth'
];

/**
 * Auth entry points that only make sense when signed out. A logged-in
 * user landing on one of these bounces to the home page — we never
 * want to show a sign-in/sign-up form to someone who already has a
 * valid session. /invite and /oauth/consent are excluded: both are
 * legitimately reached while authenticated.
 */
const SIGNED_OUT_ONLY_PREFIXES = ['/login', '/signup'];

export const load: LayoutLoad = async ({ url, fetch }) => {
  if (!browser) return { signupEnabled: false };

  const isPublicPath = PUBLIC_PATH_PREFIXES.some((p) =>
    url.pathname.startsWith(p)
  );
  const isSetupPath = url.pathname.startsWith('/setup');

  // Server-state probe: setup + signup status. Include the session cookie
  // on the same-origin call so the server can tailor /me later.
  let signupEnabled = false;
  try {
    const res = await fetch('/api/setup/status', { credentials: 'include' });
    if (res.ok) {
      const data = await res.json();
      signupEnabled = !!data.signupEnabled;
      // When the server has no admin account yet, the setup wizard is
      // the ONLY valid destination. Everything else — including /login,
      // /signup, /invite, the home page, package pages, the OAuth entry
      // points — redirects there. No `login` flow can succeed before an
      // account exists anyway, and exposing those screens just invites
      // confusion (and gives away that the server is unconfigured).
      if (data.needsSetup && !isSetupPath) {
        throw redirect(302, '/setup');
      }
      // Conversely, once setup is complete the wizard should be
      // unreachable — sending people here would only confuse them.
      if (!data.needsSetup && isSetupPath) {
        throw redirect(302, '/login');
      }
    }
  } catch (e) {
    if (e && typeof e === 'object' && 'status' in e) throw e;
  }

  // Ask the server who we are. The session cookie (if any) is sent
  // automatically; if it's invalid or missing, /me returns 401 and we
  // treat the user as signed out.
  let user: User | null = null;
  try {
    const res = await fetch('/api/auth/me', { credentials: 'include' });
    if (res.ok) {
      const data = await res.json();
      user = {
        id: data.userId,
        email: data.email,
        name: data.displayName,
        role: data.role,
        isAdmin: !!data.isAdmin,
        mustChangePassword: !!data.mustChangePassword,
        avatarUrl: data.avatarUrl ?? null
      };
    }
  } catch {
    // Network blip — treat as signed out. Non-public routes will bounce
    // to /login below.
  }

  auth.hydrate(user);

  // A signed-in user on /login or /signup has nothing to do there —
  // send them to the home page. Runs before the public-path bypass so
  // the auth pages aren't accessible just because they're "public".
  if (user && SIGNED_OUT_ONLY_PREFIXES.some((p) => url.pathname.startsWith(p))) {
    throw redirect(302, '/');
  }

  if (!isPublicPath) {
    if (!user) {
      throw redirect(302, `/login?redirect=${encodeURIComponent(url.pathname + url.search)}`);
    }
    // Force users through /welcome until they've set a real password.
    if (user.mustChangePassword && url.pathname !== '/welcome') {
      throw redirect(302, '/welcome');
    }
  }

  return { signupEnabled };
};
