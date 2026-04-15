import { useContext } from 'react';
import { AuthContext, type AuthContextValue } from './authContextValue';

/**
 * Access the auth context. Must be used within an AuthProvider.
 *
 * Split out of `AuthContext.tsx` so that file exports components only —
 * required for Fast Refresh / HMR (`react-refresh/only-export-components`).
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
