import { useEffect, useState, type ReactNode } from 'react';
import type { User } from '@oybc/shared';
import {
  signUp as authSignUp,
  signIn as authSignIn,
  signInWithGoogle as authSignInWithGoogle,
  signInWithApple as authSignInWithApple,
  signOut as authSignOut,
  onAuthStateChanged,
} from './authService';
import { AuthContext, type AuthContextValue } from './authContextValue';

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

// `useAuth` lives in `./useAuth` so this file only exports components
// (required for Fast Refresh). Consumers should import from there:
//   import { useAuth } from '../firebase/useAuth';
