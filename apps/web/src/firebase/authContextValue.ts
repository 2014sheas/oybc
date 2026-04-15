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
  /** Sign up with email/password */
  signUp: (email: string, password: string) => Promise<User>;
  /** Sign in with email/password */
  signIn: (email: string, password: string) => Promise<User>;
  /** Sign in with Google popup */
  signInWithGoogle: () => Promise<User>;
  /** Sign in with Apple popup */
  signInWithApple: () => Promise<User>;
  /** Sign out */
  signOut: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextValue | null>(null);
