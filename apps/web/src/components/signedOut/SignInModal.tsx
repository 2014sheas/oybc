import { useEffect, useRef, useState } from 'react';
import { useAuth } from '../../firebase/useAuth';
import {
  isOfflineError,
  passwordResetSentStatus,
  sendPasswordReset,
  signInErrorMessage,
} from '../../firebase/authService';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton } from '../riso';
import { ModalArt } from './SignedOutArt';
import styles from './SignedOut.module.css';

/** Honest copy for the one offline-first exception (docs/GUEST_MODE.md):
 *  minting the anonymous uid needs one network round-trip. */
const GUEST_OFFLINE_MESSAGE = 'You’re offline. Connect to continue as a guest.';

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
  const { signIn, signUp, signInWithGoogle, signInWithApple, signInAnonymously } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  /** Address a "Forgot password?" reset went to; null hides the status line. */
  const [resetSentTo, setResetSentTo] = useState<string | null>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const isUp = mode === 'signup';

  // aria-modal, Escape → close, Tab trap, focus restore.
  const { ref: cardRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: onClose,
  });

  // Move focus into the dialog on open (WCAG 2.4.3) — onto the card container
  // rather than an action button, so an accidental Enter can't fire a popup.
  // Runs after the hook's initial-focus effect, so the card wins.
  useEffect(() => {
    cardRef.current?.focus();
  }, [cardRef]);

  // Clear a stale error / reset status when the user toggles sign-in ↔ sign-up.
  useEffect(() => {
    setError(null);
    setResetSentTo(null);
  }, [mode]);

  // Lock background scroll while the modal is open (restored on close).
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  /**
   * Run an auth action with shared busy/error handling. Errors show as
   * `signInErrorMessage` copy (a closed popup shows nothing); `mapError` lets
   * a caller override it for a specific error (e.g. the guest button's
   * offline copy) — return null to fall through to the default.
   */
  async function run(
    action: () => Promise<unknown>,
    mapError?: (err: unknown) => string | null
  ): Promise<void> {
    if (busy) return;
    setError(null);
    setBusy(true);
    try {
      await action();
      // A sign-in success unmounts us (the gate swaps trees); a reset sets
      // its own status inside `action`.
    } catch (err) {
      setError(mapError?.(err) ?? signInErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  function handleEmailSubmit(e: React.FormEvent): void {
    e.preventDefault();
    setResetSentTo(null);
    const trimmed = email.trim();
    void run(() => (isUp ? signUp(trimmed, password) : signIn(trimmed, password)));
  }

  /**
   * "Forgot password?" — send a reset link to the typed email. An empty or
   * malformed address gets the email field's own validation message, exactly
   * like submitting the form; the confirmation reads the same whether or not
   * an account uses the address (`sendPasswordReset` is enumeration-safe).
   */
  function handleForgotPassword(): void {
    if (busy || !emailRef.current?.reportValidity()) return;
    setResetSentTo(null);
    void run(async () => {
      setResetSentTo(await sendPasswordReset(email));
    });
  }

  return (
    <div className={styles.soAuthScrim} onClick={onClose} role="presentation">
      <div
        ref={cardRef}
        className={styles.soAuthCard}
        role="dialog"
        aria-label={isUp ? 'Create your account' : 'Sign in to OYBC'}
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <button type="button" className={styles.soAuthX} onClick={onClose} aria-label="Close">
          ✕
        </button>

        <ModalArt />

        <div className={styles.soKicker}>{isUp ? 'Create your account' : 'Welcome back'}</div>
        <div className={styles.soAuthH}>{isUp ? 'Start your first board.' : 'Sign in to OYBC.'}</div>

        <div className={styles.soAuthBtns}>
          <RisoButton
            kind="dark"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void run(signInWithApple)}
          >
            Continue with Apple
          </RisoButton>
          <RisoButton
            kind="neutral"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void run(signInWithGoogle)}
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
              ref={emailRef}
              id="so-auth-email"
              className={styles.soInput}
              type="email"
              placeholder="you@example.com"
              autoComplete="email"
              value={email}
              onChange={(e) => {
                setEmail(e.target.value);
                setResetSentTo(null);
              }}
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

          {!isUp && (
            <button
              type="button"
              className={styles.soForgot}
              onClick={handleForgotPassword}
              disabled={busy}
            >
              Forgot password?
            </button>
          )}

          {error && <div className={styles.soError}>{error}</div>}
          {!isUp && !error && resetSentTo && (
            <div className={styles.soStatus} role="status">
              {passwordResetSentStatus(resetSentTo)}
            </div>
          )}

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

        <div className={styles.soGuestRow}>
          <RisoButton
            kind="ghost"
            fullWidth
            disabled={busy}
            onClick={() =>
              void run(signInAnonymously, (err) =>
                isOfflineError(err) ? GUEST_OFFLINE_MESSAGE : null
              )
            }
          >
            Continue without an account
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
