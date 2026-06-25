import { useEffect, useRef, useState } from 'react';
import { useAuth } from '../../firebase/useAuth';
import { RisoButton } from '../riso';
import { ModalArt } from './SignedOutArt';
import styles from './SignedOut.module.css';

export type AuthMode = 'signin' | 'signup';

export interface SignInModalProps {
  /** Whether the modal opens in sign-in or sign-up copy. */
  mode: AuthMode;
  /** Dismiss the modal (scrim click, ✕, or Escape). */
  onClose: () => void;
  /** Toggle between sign-in and sign-up without closing. */
  onSwitchMode: (mode: AuthMode) => void;
}

/**
 * Sign-in / sign-up modal for the signed-out home. Wired to the real
 * `useAuth` (Apple / Google / email+password) — on success the AuthProvider's
 * user becomes non-null and `AuthGate` swaps the whole signed-out tree for the
 * app, unmounting this modal (so there's no explicit success callback).
 *
 * The handoff prototype showed an email-only field; real email auth needs a
 * password, so one is added here (the README explicitly says to replace the
 * prototype's stub auth).
 */
export function SignInModal({ mode, onClose, onSwitchMode }: SignInModalProps): React.ReactElement {
  const { signIn, signUp, signInWithGoogle, signInWithApple } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const cardRef = useRef<HTMLDivElement>(null);
  const isUp = mode === 'signup';

  // Move focus into the dialog on open (WCAG 2.4.3) — onto the card container
  // rather than an action button, so an accidental Enter can't fire a popup.
  useEffect(() => {
    cardRef.current?.focus();
  }, []);

  // Clear a stale error when the user toggles sign-in ↔ sign-up.
  useEffect(() => {
    setError(null);
  }, [mode]);

  // Lock background scroll while the modal is open (restored on close).
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  /** Run an auth action with shared busy/error handling. */
  async function run(action: () => Promise<unknown>, fallback: string): Promise<void> {
    if (busy) return;
    setError(null);
    setBusy(true);
    try {
      await action();
      // On success the gate unmounts us; no further state work needed.
    } catch (err) {
      setError(err instanceof Error ? err.message : fallback);
    } finally {
      setBusy(false);
    }
  }

  function handleEmailSubmit(e: React.FormEvent): void {
    e.preventDefault();
    const trimmed = email.trim();
    void run(
      () => (isUp ? signUp(trimmed, password) : signIn(trimmed, password)),
      isUp ? 'Could not create account' : 'Could not sign in'
    );
  }

  return (
    <div className={styles.soAuthScrim} onClick={onClose} role="presentation">
      <div
        ref={cardRef}
        tabIndex={-1}
        className={styles.soAuthCard}
        role="dialog"
        aria-modal="true"
        aria-label={isUp ? 'Create your account' : 'Sign in to OYBC'}
        onClick={(e) => e.stopPropagation()}
      >
        <button type="button" className={styles.soAuthX} onClick={onClose} aria-label="Close">
          ✕
        </button>

        <ModalArt />

        <div className={styles.soKicker}>{isUp ? 'Create your account' : 'Welcome back'}</div>
        <div className={styles.soAuthH}>{isUp ? 'Start your first board.' : 'Sign in to OYBC.'}</div>
        <p className={styles.soAuthP}>
          {isUp
            ? 'Free to start. Your boards, streaks, and GREENLOG history sync across every device.'
            : 'Pick up your boards and streaks right where you left them.'}
        </p>

        <div className={styles.soAuthBtns}>
          <RisoButton
            kind="dark"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void run(signInWithApple, 'Apple sign-in failed')}
          >
            Continue with Apple
          </RisoButton>
          <RisoButton
            kind="neutral"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void run(signInWithGoogle, 'Google sign-in failed')}
          >
            Continue with Google
          </RisoButton>
        </div>

        <div className={styles.soAuthAlt}>or</div>

        <form onSubmit={handleEmailSubmit}>
          <div className={styles.soAuthField}>
            <label htmlFor="so-auth-email" className={styles.soFieldLabel}>
              Email
            </label>
            <input
              id="so-auth-email"
              className={styles.soInput}
              type="email"
              placeholder="you@example.com"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
            />
          </div>
          <div className={styles.soAuthField}>
            <label htmlFor="so-auth-password" className={styles.soFieldLabel}>
              Password
            </label>
            <input
              id="so-auth-password"
              className={styles.soInput}
              type="password"
              placeholder="••••••••"
              autoComplete={isUp ? 'new-password' : 'current-password'}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              minLength={6}
            />
          </div>

          {error && <div className={styles.soError}>{error}</div>}

          <RisoButton kind="primary" size="large" fullWidth type="submit" disabled={busy}>
            {busy ? 'Please wait…' : isUp ? 'Create account' : 'Continue with email'}
          </RisoButton>
        </form>

        <div className={styles.soAuthFoot}>
          {isUp ? 'Already have an account? ' : 'New to OYBC? '}
          <button type="button" onClick={() => onSwitchMode(isUp ? 'signin' : 'signup')}>
            {isUp ? 'Sign in' : 'Get started'}
          </button>
        </div>
      </div>
    </div>
  );
}
