import { useAuth } from '../firebase/useAuth';
import { SignedOutHome } from './signedOut/SignedOutHome';
import { RisoBrandMark } from './riso';
import styles from './AuthGate.module.css';

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * AuthGate — gates the app behind authentication.
 *
 * - While the initial auth state resolves: a quiet Riso loading screen.
 * - Signed in: renders `children` (the authenticated app).
 * - Signed out: the Riso signed-out marketing home (`SignedOutHome`), which
 *   owns the sign-in/up modal and runs auth through the real `useAuth`. On
 *   success the user becomes non-null and this gate swaps to `children`.
 *
 * @param props.children - Content to show when authenticated
 */
export function AuthGate({ children }: { children: React.ReactNode }): React.ReactElement {
  const { user, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className={`${styles.loading} riso-grain`}>
        <RisoBrandMark size={56} />
        <span className={styles.loadingLabel}>Loading…</span>
      </div>
    );
  }

  if (user) {
    return <>{children}</>;
  }

  return <SignedOutHome />;
}
