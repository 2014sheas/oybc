import { createContext } from 'react';
import type { User } from '@oybc/shared';

/**
 * Shape of the value provided by `AuthProvider`. Split out of
 * `AuthContext.tsx` (component file) + `useAuth.ts` (hook file) so
 * neither leaks a non-component export and Fast Refresh stays happy.
 */
export interface AuthContextValue {
  /** The authenticated user, or null if signed out */
  user: User | null;
  /** True while the initial auth state is being resolved */
  isLoading: boolean;
  /**
   * True when the current session is a Firebase anonymous (guest) user
   * (docs/GUEST_MODE.md). Session-derived, never persisted on the User type.
   */
  isAnonymous: boolean;
  /** Sign up with email/password */
  signUp: (email: string, password: string) => Promise<User>;
  /** Sign in with email/password */
  signIn: (email: string, password: string) => Promise<User>;
  /** Sign in with Google popup */
  signInWithGoogle: () => Promise<User>;
  /** Sign in with Apple popup */
  signInWithApple: () => Promise<User>;
  /** Sign in as a guest (Firebase anonymous auth) */
  signInAnonymously: () => Promise<User>;
  /**
   * Reconcile local auth state after a guest→account upgrade. Linking mutates
   * `auth.currentUser` without firing the auth-state listener, so callers invoke
   * this after a successful `link*` to refresh `user` (email/displayName) and
   * clear `isAnonymous`.
   */
  refreshAfterUpgrade: () => Promise<void>;
  /** Sign out */
  signOut: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextValue | null>(null);
