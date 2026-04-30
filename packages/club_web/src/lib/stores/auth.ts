import { writable, derived } from 'svelte/store';

export type UserRole = 'owner' | 'admin' | 'member' | 'viewer';

export interface User {
  id: string;
  email: string;
  name: string;
  role: UserRole;
  /** Legacy — kept in sync with role >= admin; remove once nothing reads it. */
  isAdmin: boolean;
  /** When true, the user must change their password before any other app
   * surface becomes accessible. Enforced by the root layout. */
  mustChangePassword: boolean;
  /** URL path to the user's avatar image, or null if none set. */
  avatarUrl: string | null;
}

export interface AuthState {
  user: User | null;
}

const ROLE_ORDER: UserRole[] = ['owner', 'admin', 'member', 'viewer'];

/** True when [role] is at least as privileged as [min]. */
export function roleIsAtLeast(role: UserRole | undefined, min: UserRole): boolean {
  if (!role) return false;
  return ROLE_ORDER.indexOf(role) <= ROLE_ORDER.indexOf(min);
}

// The session itself lives in an HttpOnly cookie the server sets at login
// and the browser attaches to every same-origin request. The store only
// mirrors the *user* portion so UI can render without calling /me on every
// paint. On a cold page load, +layout.ts calls /api/auth/me and seeds this.
function createAuthStore() {
  const { subscribe, set, update } = writable<AuthState>({ user: null });

  return {
    subscribe,

    /** Populate from /api/auth/me after a fresh page load. */
    hydrate(user: User | null) {
      set({ user });
    },

    /** Called after a successful /api/auth/login. */
    login(user: User) {
      set({ user });
    },

    /** Clear local state. The server's /api/auth/logout clears cookies. */
    logout() {
      set({ user: null });
    },

    updateUser(user: User) {
      update((s) => ({ ...s, user }));
    },

    /** Call after the user completes the forced password reset so the
     *  root layout lets them through. */
    clearMustChangePassword() {
      update((s) => {
        if (!s.user) return s;
        return { ...s, user: { ...s.user, mustChangePassword: false } };
      });
    }
  };
}

export const auth = createAuthStore();

export const isAuthenticated = derived(auth, ($auth) => $auth.user !== null);
export const currentRole = derived(auth, ($auth) => $auth.user?.role);
export const isAdmin = derived(auth, ($auth) =>
  roleIsAtLeast($auth.user?.role, 'admin')
);
export const isOwner = derived(auth, ($auth) => $auth.user?.role === 'owner');
export const mustChangePassword = derived(
  auth,
  ($auth) => $auth.user?.mustChangePassword ?? false
);
