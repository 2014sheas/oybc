import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { User } from '@oybc/shared';
import {
  signUp as authSignUp,
  signIn as authSignIn,
  signInWithGoogle as authSignInWithGoogle,
  signInWithApple as authSignInWithApple,
  signOut as authSignOut,
  onAuthStateChanged,
} from './authService';

// ─── Types ────────────────────────────────────────────────────────────────────

interface AuthContextValue {
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

// ─── Context ──────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | null>(null);

// ─── Provider ─────────────────────────────────────────────────────────────────

/**
 * AuthProvider wraps the app and provides auth state + actions via React context.
 *
 * Subscribes to Firebase onAuthStateChanged on mount. While the initial state
 * is resolving, `isLoading` is true and `user` is null.
 *
 * @param props.children - App content to wrap
 */
export function AuthProvider({ children }: { children: ReactNode }): React.ReactElement {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged((authUser) => {
      setUser(authUser);
      setIsLoading(false);
    });
    return unsubscribe;
  }, []);

  const value: AuthContextValue = {
    user,
    isLoading,
    signUp: authSignUp,
    signIn: authSignIn,
    signInWithGoogle: authSignInWithGoogle,
    signInWithApple: authSignInWithApple,
    signOut: authSignOut,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Access the auth context. Must be used within an AuthProvider.
 *
 * @returns Auth state and actions
 * @throws If used outside of AuthProvider
 */
export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
