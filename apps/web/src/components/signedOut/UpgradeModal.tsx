import { useEffect, useRef, useState } from 'react';
import { useAuth } from '../../firebase/useAuth';
import {
  friendlyError,
  isCredentialCollision,
  linkApple,
  linkGoogle,
  linkPassword,
} from '../../firebase/accountSecurity';
import { clearSyncQueue } from '../../db/operations/syncQueue';
import { RisoButton } from '../riso';
import styles from './SignedOut.module.css';

export interface UpgradeModalProps {
  /** Dismiss the modal (scrim click, ✕, or Escape). Disabled while busy. */
  onClose: () => void;
}

/** Which identity the guest tried to link when a collision was hit — needed
 *  to know which normal `signIn*` to re-run after the discard. */
type Collision = { kind: 'google' } | { kind: 'apple' } | { kind: 'password'; email: string; password: string };

/**
 * Guest→account upgrade modal (docs/GUEST_MODE.md §Upgrade). Offers Apple /
 * Google / email+password, each calling the existing `accountSecurity.ts`
 * `link*` on the anonymous `currentUser`, then `refreshAfterUpgrade()` to
 * reconcile the local row (linking doesn't fire `onAuthStateChanged`).
 *
 * Reuses `SignInModal`'s auth-card visual language (`SignedOut.module.css`)
 * since it's the same card/scrim/provider-button family, just triggered
 * in-app instead of pre-auth.
 *
 * **Collision edge**: if a link fails with `credential-already-in-use` /
 * `email-already-in-use`, the identity already belongs to a different
 * account. Merging two Firestore trees is out of scope — the modal swaps to
 * a confirm step ("discard this guest's boards, sign into the existing
 * account instead"). Confirming deletes the anonymous user FIRST (purges the
 * near-empty anon tree + wipes local Dexie, so no orphan accrual), then runs
 * the normal `signInWith*`/`signIn` for the existing identity.
 */
export function UpgradeModal({ onClose }: UpgradeModalProps): React.ReactElement {
  const { signInWithGoogle, signInWithApple, signIn, refreshAfterUpgrade } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [collision, setCollision] = useState<Collision | null>(null);
  const cardRef = useRef<HTMLDivElement>(null);

  // Move focus into the dialog on open (WCAG 2.4.3), mirroring SignInModal.
  useEffect(() => {
    cardRef.current?.focus();
  }, []);

  // Lock background scroll while the modal is open (restored on close).
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  // Escape closes — unless a link/delete op is in flight (this modal has two
  // call sites, so the handler lives here rather than duplicated per-parent).
  useEffect(() => {
    if (busy) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [busy, onClose]);

  /** Run a link action; on collision, swap to the confirm step instead of
   *  surfacing a raw error. */
  async function runLink(action: () => Promise<void>, onCollision: Collision): Promise<void> {
    if (busy) return;
    setError(null);
    setBusy(true);
    try {
      await action();
      await refreshAfterUpgrade();
      onClose();
    } catch (err) {
      if (isCredentialCollision(err)) {
        setCollision(onCollision);
      } else {
        setError(friendlyError(err));
      }
    } finally {
      setBusy(false);
    }
  }

  function handleEmailSubmit(e: React.FormEvent): void {
    e.preventDefault();
    const trimmed = email.trim();
    void runLink(() => linkPassword(trimmed, password), { kind: 'password', email: trimmed, password });
  }

  /** Collision confirm — verify before destroy: sign into the pre-existing
   *  account FIRST (while still anonymous). A wrong password / cancelled OAuth
   *  throws here and leaves the guest session + local data intact — the old
   *  "delete anon first" order could wipe guest data and THEN fail on a wrong
   *  password (the anon email password rarely matches the existing account's).
   *  On success we've switched accounts; clear the stale anon sync queue so its
   *  pending pushes don't fail under the new uid. The near-empty anon account
   *  orphans server-side; the guest's local rows are userId-filtered out. */
  async function confirmSwitchAccount(): Promise<void> {
    if (!collision || busy) return;
    setBusy(true);
    setError(null);
    try {
      if (collision.kind === 'google') await signInWithGoogle();
      else if (collision.kind === 'apple') await signInWithApple();
      else await signIn(collision.email, collision.password);
      await clearSyncQueue();
      onClose();
    } catch (err) {
      // Sign-in failed (e.g. wrong password) — nothing was destroyed. Keep the
      // confirm step open so the user can retry or cancel.
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  if (collision) {
    return (
      <div className={styles.soAuthScrim} onClick={busy ? undefined : onClose} role="presentation">
        <div
          ref={cardRef}
          tabIndex={-1}
          className={styles.soAuthCard}
          role="dialog"
          aria-modal="true"
          aria-label="That account already exists"
          onClick={(e) => e.stopPropagation()}
        >
          {!busy && (
            <button type="button" className={styles.soAuthX} onClick={onClose} aria-label="Close">
              ✕
            </button>
          )}

          <div className={styles.soKicker}>Account already exists</div>
          <div className={styles.soAuthH}>Sign into it instead?</div>
          <p className={styles.soAuthP}>
            You’ll switch to that account on this device. Your guest boards here won’t carry over —
            they can’t be merged into it.
          </p>

          {error && <div className={styles.soError}>{error}</div>}

          <div className={styles.soConfirmActions}>
            <RisoButton kind="ghost" disabled={busy} onClick={() => setCollision(null)}>
              Cancel
            </RisoButton>
            <RisoButton kind="primary" disabled={busy} onClick={() => void confirmSwitchAccount()}>
              {busy ? 'Please wait…' : 'Sign in'}
            </RisoButton>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.soAuthScrim} onClick={busy ? undefined : onClose} role="presentation">
      <div
        ref={cardRef}
        tabIndex={-1}
        className={styles.soAuthCard}
        role="dialog"
        aria-modal="true"
        aria-label="Save your account"
        onClick={(e) => e.stopPropagation()}
      >
        {!busy && (
          <button type="button" className={styles.soAuthX} onClick={onClose} aria-label="Close">
            ✕
          </button>
        )}

        <div className={styles.soKicker}>Save your account</div>
        <div className={styles.soAuthH}>Don’t lose this board.</div>
        <p className={styles.soAuthP}>
          Add a sign-in method to keep your boards, streaks, and GREENLOG history — and sync them
          across every device.
        </p>

        <div className={styles.soAuthBtns}>
          <RisoButton
            kind="dark"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void runLink(linkApple, { kind: 'apple' })}
          >
            Continue with Apple
          </RisoButton>
          <RisoButton
            kind="neutral"
            size="large"
            fullWidth
            disabled={busy}
            onClick={() => void runLink(linkGoogle, { kind: 'google' })}
          >
            Continue with Google
          </RisoButton>
        </div>

        <div className={styles.soAuthAlt}>or</div>

        <form onSubmit={handleEmailSubmit}>
          <div className={styles.soAuthField}>
            <label htmlFor="upgrade-email" className={styles.soFieldLabel}>
              Email
            </label>
            <input
              id="upgrade-email"
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
            <label htmlFor="upgrade-password" className={styles.soFieldLabel}>
              Password
            </label>
            <input
              id="upgrade-password"
              className={styles.soInput}
              type="password"
              placeholder="••••••••"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              minLength={6}
            />
          </div>

          {error && <div className={styles.soError}>{error}</div>}

          <RisoButton kind="primary" size="large" fullWidth type="submit" disabled={busy}>
            {busy ? 'Please wait…' : 'Save with email'}
          </RisoButton>
        </form>
      </div>
    </div>
  );
}
