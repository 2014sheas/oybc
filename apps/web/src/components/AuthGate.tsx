import { useState } from 'react';
import { useAuth } from '../firebase/AuthContext';
import styles from './AuthGate.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

type AuthMode = 'signIn' | 'signUp';

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * AuthGate — Login/register form shown when the user is not authenticated.
 *
 * Supports email/password, Google, and Apple sign-in. Renders children
 * when authenticated, or the auth form when not.
 *
 * @param props.children - Content to show when authenticated
 */
export function AuthGate({ children }: { children: React.ReactNode }): React.ReactElement {
  const { user, isLoading, signIn, signUp, signInWithGoogle, signInWithApple } = useAuth();

  const [mode, setMode] = useState<AuthMode>('signIn');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  if (isLoading) {
    return <div className={styles.loading}>Loading...</div>;
  }

  // ── Authenticated state — render children directly ────────────────────
  if (user) {
    return <>{children}</>;
  }

  // ── Form handlers ───────────────────────────────────────────────────────

  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();
    setError(null);
    setIsSubmitting(true);

    try {
      if (mode === 'signUp') {
        await signUp(email.trim(), password);
      } else {
        await signIn(email.trim(), password);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Authentication failed');
    } finally {
      setIsSubmitting(false);
    }
  }

  async function handleGoogleSignIn(): Promise<void> {
    setError(null);
    try {
      await signInWithGoogle();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Google sign-in failed');
    }
  }

  async function handleAppleSignIn(): Promise<void> {
    setError(null);
    try {
      await signInWithApple();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Apple sign-in failed');
    }
  }

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <div className={styles.card}>
        <h2 className={styles.title}>
          {mode === 'signIn' ? 'Sign In' : 'Create Account'}
        </h2>

        <form onSubmit={(e) => void handleSubmit(e)} className={styles.form}>
          <input
            type="email"
            className={styles.input}
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            autoComplete="email"
          />
          <input
            type="password"
            className={styles.input}
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            minLength={6}
            autoComplete={mode === 'signUp' ? 'new-password' : 'current-password'}
          />

          {error && <div className={styles.error}>{error}</div>}

          <button
            type="submit"
            className={styles.submitButton}
            disabled={isSubmitting}
          >
            {isSubmitting
              ? 'Loading...'
              : mode === 'signIn'
                ? 'Sign In'
                : 'Create Account'}
          </button>
        </form>

        <div className={styles.divider}>
          <span>or</span>
        </div>

        <div className={styles.socialButtons}>
          <button
            type="button"
            className={styles.googleButton}
            onClick={() => void handleGoogleSignIn()}
          >
            Continue with Google
          </button>
          <button
            type="button"
            className={styles.appleButton}
            onClick={() => void handleAppleSignIn()}
          >
            Continue with Apple
          </button>
        </div>

        <p className={styles.switchMode}>
          {mode === 'signIn' ? (
            <>
              No account?{' '}
              <button
                type="button"
                className={styles.switchButton}
                onClick={() => { setMode('signUp'); setError(null); }}
              >
                Create one
              </button>
            </>
          ) : (
            <>
              Already have an account?{' '}
              <button
                type="button"
                className={styles.switchButton}
                onClick={() => { setMode('signIn'); setError(null); }}
              >
                Sign in
              </button>
            </>
          )}
        </p>
      </div>
    </div>
  );
}
