import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../firebase/useAuth';
import { db } from '../db/database';
import {
  APPLE_PROVIDER_ID,
  EMPTY_PROVIDER_STATE,
  GOOGLE_PROVIDER_ID,
  LAST_PROVIDER_ERROR,
  deleteAccount,
  getProviderState,
  isRecentLoginRequired,
  linkApple,
  linkGoogle,
  linkPassword,
  reauthWithApple,
  reauthWithGoogle,
  reauthWithPassword,
  reconcileEmailIfChanged,
  sendPasswordResetToCurrentUser,
  unlinkProvider,
  updateAccountEmail,
  updateAccountPassword,
  type ProviderState,
} from '../firebase/accountSecurity';
import styles from './AccountSecurityPage.module.css';

/** Which action sheet is open. */
type SheetMode = 'changeEmail' | 'changePassword' | 'addPassword' | 'deleteAccount' | null;

/**
 * Account & security (Phase 5b, web). Net-new screen mirroring iOS §5c.
 * Sections: **Sign in** (change email/password, add password — 5b-i),
 * **Connected accounts** (Apple/Google link/unlink — 5b-ii), and **Danger zone**
 * (delete account — 5b-iii).
 *
 * The dev bypass user has no real Firebase session, so the live auth flows here
 * are exercised on a real account (relay-to-user), like the iOS screen.
 */
export function AccountSecurityPage(): React.ReactElement {
  const { user } = useAuth();
  const localUser = useLiveQuery(
    () => (user?.id ? db.users.get(user.id) : undefined),
    [user?.id],
  );
  const email = localUser?.email ?? user?.email ?? '';

  const [providers, setProviders] = useState<ProviderState>(EMPTY_PROVIDER_STATE);
  const [sheet, setSheet] = useState<SheetMode>(null);
  const [pendingEmail, setPendingEmail] = useState<string | null>(null);
  // Connected-accounts (5b-ii) per-action busy + error.
  const [providerBusy, setProviderBusy] = useState<string | null>(null);
  const [providerError, setProviderError] = useState<string | null>(null);

  // On mount: load linked-provider state + heal the local email if a
  // verifyBeforeUpdateEmail flow completed out-of-band since last visit.
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const state = await getProviderState();
      if (!cancelled) setProviders(state);
      await reconcileEmailIfChanged();
    })();
    return () => {
      cancelled = true;
    };
  }, [user?.id]);

  const refreshProviders = async (): Promise<void> => {
    setProviders(await getProviderState());
  };

  /** Link or unlink a provider, then re-read state. `key` ('google'|'apple')
   *  drives the per-row busy spinner; errors route through `friendlyError`. */
  const runProviderAction = async (key: string, action: () => Promise<void>): Promise<void> => {
    setProviderBusy(key);
    setProviderError(null);
    try {
      await action();
      await refreshProviders();
    } catch (err) {
      setProviderError(friendlyError(err));
    } finally {
      // Clear only our own slot — a late-resolving action must not wipe a
      // different action the user started in the meantime.
      setProviderBusy((prev) => (prev === key ? null : prev));
    }
  };

  return (
    <div className={styles.container}>
      <div className={styles.subPageHeader}>
        <Link to="/profile" className={styles.backLink} aria-label="Back to Profile">
          ‹
        </Link>
        <h1 className={styles.title}>Account &amp; security</h1>
      </div>
      <p className={styles.intro}>
        Manage how you sign in to On Your Bingo Card.
      </p>

      {pendingEmail && (
        <p className={styles.pendingBanner}>
          Check <b>{pendingEmail}</b> for a verification link to finish changing your email.
          Your address updates here once you confirm it.
        </p>
      )}

      <div className={styles.sectionLabel}>Sign in</div>
      <div className={styles.card}>
        <div className={styles.infoRow}>
          <span className={styles.infoLabel}>Email</span>
          <span className={styles.infoValue}>{email || '—'}</span>
        </div>

        {providers.hasPassword ? (
          <>
            <button
              type="button"
              className={styles.actionRow}
              onClick={() => setSheet('changeEmail')}
            >
              <span className={styles.actionLabel}>Change email</span>
              <span className={styles.actionArrow} aria-hidden="true">
                ›
              </span>
            </button>
            <button
              type="button"
              className={styles.actionRow}
              onClick={() => setSheet('changePassword')}
            >
              <span className={styles.actionLabel}>Change password</span>
              <span className={styles.actionArrow} aria-hidden="true">
                ›
              </span>
            </button>
          </>
        ) : (
          <button
            type="button"
            className={styles.actionRow}
            onClick={() => setSheet('addPassword')}
          >
            <span className={styles.actionLabel}>Add a password</span>
            <span className={styles.actionArrow} aria-hidden="true">
              ›
            </span>
          </button>
        )}
      </div>

      <div className={styles.sectionLabel}>Connected accounts</div>
      <div className={styles.card}>
        <ProviderRow
          name="Apple"
          linked={providers.hasApple}
          canUnlink={providers.providerCount > 1}
          busy={providerBusy === 'apple'}
          anyBusy={providerBusy !== null}
          onConnect={() => void runProviderAction('apple', linkApple)}
          onDisconnect={() => void runProviderAction('apple', () => unlinkProvider(APPLE_PROVIDER_ID))}
        />
        <ProviderRow
          name="Google"
          linked={providers.hasGoogle}
          canUnlink={providers.providerCount > 1}
          busy={providerBusy === 'google'}
          anyBusy={providerBusy !== null}
          onConnect={() => void runProviderAction('google', linkGoogle)}
          onDisconnect={() => void runProviderAction('google', () => unlinkProvider(GOOGLE_PROVIDER_ID))}
        />
      </div>
      {providerError && (
        <p className={styles.sectionError} role="alert">
          {providerError}
        </p>
      )}

      <div className={styles.sectionLabel}>Danger zone</div>
      <div className={`${styles.card} ${styles.dangerCard}`}>
        <button
          type="button"
          className={styles.dangerRow}
          onClick={() => setSheet('deleteAccount')}
        >
          <span className={styles.dangerLabel}>Delete account</span>
          <span className={styles.actionArrow} aria-hidden="true">
            ›
          </span>
        </button>
      </div>

      {sheet === 'changePassword' && (
        <ChangePasswordSheet onClose={() => setSheet(null)} />
      )}
      {sheet === 'changeEmail' && (
        <ChangeEmailSheet
          onClose={() => setSheet(null)}
          onPending={(addr) => {
            setPendingEmail(addr);
            setSheet(null);
          }}
        />
      )}
      {sheet === 'addPassword' && (
        <AddPasswordSheet
          email={email}
          onClose={() => setSheet(null)}
          onDone={async () => {
            await refreshProviders();
            setSheet(null);
          }}
        />
      )}
      {sheet === 'deleteAccount' && (
        <DeleteAccountSheet providers={providers} onClose={() => setSheet(null)} />
      )}
    </div>
  );
}

// ─── Sheets ───────────────────────────────────────────────────────────────────

/** Map a Firebase/Error to a user-facing string (never a raw provider code). */
function friendlyError(err: unknown): string {
  if (isRecentLoginRequired(err)) {
    return 'For your security, the current password didn’t match or your session is stale. Re-enter it and try again.';
  }
  // Connected-accounts (5b-ii) cases.
  if ((err as { message?: string } | undefined)?.message === LAST_PROVIDER_ERROR) {
    return 'You can’t disconnect your only sign-in method — add another first.';
  }
  const code = (err as { code?: string } | undefined)?.code;
  if (code === 'auth/wrong-password' || code === 'auth/invalid-credential') {
    return 'That current password is incorrect.';
  }
  if (code === 'auth/weak-password') return 'Pick a stronger password (at least 6 characters).';
  if (code === 'auth/email-already-in-use') return 'That email is already in use by another account.';
  if (code === 'auth/invalid-email') return 'That email address looks invalid.';
  if (code === 'auth/credential-already-in-use' || code === 'auth/account-exists-with-different-credential') {
    return 'That account is already linked to a different On Your Bingo Card account.';
  }
  // Popup dismissed/cancelled — benign; don't alarm the user.
  if (code === 'auth/popup-closed-by-user' || code === 'auth/cancelled-popup-request') {
    return 'Connection cancelled.';
  }
  // Popup blocked — retrying won't help; the user must allow popups.
  if (code === 'auth/popup-blocked') {
    return 'Your browser blocked the sign-in popup — allow popups for this site, then try again.';
  }
  return 'Something went wrong. Please try again.';
}

/** A single connected-account row (Apple / Google) with link/unlink action. */
function ProviderRow({
  name,
  linked,
  canUnlink,
  busy,
  anyBusy,
  onConnect,
  onDisconnect,
}: {
  name: string;
  linked: boolean;
  canUnlink: boolean;
  /** This row's own action is in flight (drives the spinner). */
  busy: boolean;
  /** ANY provider action is in flight — disables both rows so two link/unlink
   *  popups can't run concurrently and race on auth state. */
  anyBusy: boolean;
  onConnect: () => void;
  onDisconnect: () => void;
}): React.ReactElement {
  return (
    <div className={styles.providerRow}>
      <span className={styles.providerName}>{name}</span>
      <span className={styles.providerMeta}>
        <span
          className={linked ? styles.providerDotOn : styles.providerDot}
          aria-hidden="true"
        />
        {linked ? 'Connected' : 'Not connected'}
      </span>
      {linked ? (
        <button
          type="button"
          className={styles.providerButton}
          onClick={onDisconnect}
          disabled={anyBusy || !canUnlink}
          title={!canUnlink ? 'Add another sign-in method before disconnecting this one.' : undefined}
        >
          {busy ? '…' : 'Disconnect'}
        </button>
      ) : (
        <button
          type="button"
          className={styles.providerButtonPrimary}
          onClick={onConnect}
          disabled={anyBusy}
        >
          {busy ? '…' : 'Connect'}
        </button>
      )}
    </div>
  );
}

/** Change-password sheet — reauth with current password, then set the new one. */
function ChangePasswordSheet({ onClose }: { onClose: () => void }): React.ReactElement {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resetSent, setResetSent] = useState(false);

  const submit = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await reauthWithPassword(current);
      await updateAccountPassword(next);
      onClose();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  };

  const forgot = async (): Promise<void> => {
    setError(null);
    try {
      await sendPasswordResetToCurrentUser();
      setResetSent(true);
    } catch (err) {
      setError(friendlyError(err));
    }
  };

  return (
    <Sheet title="Change password" onClose={onClose} busy={busy}>
      <Field label="Current password" type="password" value={current} onChange={setCurrent} autoFocus />
      <Field label="New password" type="password" value={next} onChange={setNext} />
      <button type="button" className={styles.linkButton} onClick={() => void forgot()}>
        {resetSent ? 'Reset email sent ✓' : 'Forgot current password?'}
      </button>
      {error && <p className={styles.sheetError}>{error}</p>}
      <SheetActions onClose={onClose} onSubmit={() => void submit()} busy={busy} disabled={!current || next.length < 6} submitLabel="Update password" />
    </Sheet>
  );
}

/** Change-email sheet — reauth, then begin verifyBeforeUpdateEmail. */
function ChangeEmailSheet({
  onClose,
  onPending,
}: {
  onClose: () => void;
  onPending: (email: string) => void;
}): React.ReactElement {
  const [current, setCurrent] = useState('');
  const [nextEmail, setNextEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await reauthWithPassword(current);
      await updateAccountEmail(nextEmail);
      onPending(nextEmail.trim());
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Change email" onClose={onClose} busy={busy}>
      <p className={styles.sheetBody}>
        We’ll email a verification link to the new address. Your email changes once you click it.
      </p>
      <Field label="Current password" type="password" value={current} onChange={setCurrent} autoFocus />
      <Field label="New email" type="email" value={nextEmail} onChange={setNextEmail} />
      {error && <p className={styles.sheetError}>{error}</p>}
      <SheetActions onClose={onClose} onSubmit={() => void submit()} busy={busy} disabled={!current || !nextEmail} submitLabel="Send verification" />
    </Sheet>
  );
}

/** Add-password sheet — link an email/password credential to an OAuth account. */
function AddPasswordSheet({
  email,
  onClose,
  onDone,
}: {
  email: string;
  onClose: () => void;
  onDone: () => void | Promise<void>;
}): React.ReactElement {
  const [next, setNext] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    if (!email) {
      setError('Your account has no email to attach a password to.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await linkPassword(email, next);
      await onDone();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet title="Add a password" onClose={onClose} busy={busy}>
      <p className={styles.sheetBody}>
        Add a password to <b>{email || 'your account'}</b> so you can also sign in with email — and
        change your email or password later.
      </p>
      <Field label="New password" type="password" value={next} onChange={setNext} autoFocus />
      {error && <p className={styles.sheetError}>{error}</p>}
      <SheetActions onClose={onClose} onSubmit={() => void submit()} busy={busy} disabled={next.length < 6} submitLabel="Add password" />
    </Sheet>
  );
}

/**
 * Delete-account sheet — reauthenticate (password field, or OAuth popup), then
 * permanently delete. On success the Firebase auth listener nils the session and
 * the app swaps to the signed-out home, so this component unmounts (busy stays
 * true until then). `busy` is only reset on failure.
 */
function DeleteAccountSheet({
  providers,
  onClose,
}: {
  providers: ProviderState;
  onClose: () => void;
}): React.ReactElement {
  const [current, setCurrent] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      // Reauth (delete requires recent login) using whatever provider they have.
      if (providers.hasPassword) await reauthWithPassword(current);
      else if (providers.hasGoogle) await reauthWithGoogle();
      else if (providers.hasApple) await reauthWithApple();
      await deleteAccount();
      // Success: auth-state listener tears down the session → signed-out home.
    } catch (err) {
      setError(friendlyError(err));
      setBusy(false);
    }
  };

  return (
    <Sheet title="Delete your account?" onClose={onClose} busy={busy}>
      <p className={styles.sheetBody}>
        This permanently erases every board, streak, and GREENLOG across all your devices. It
        can’t be undone.
      </p>
      {providers.hasPassword ? (
        <Field
          label="Current password"
          type="password"
          value={current}
          onChange={setCurrent}
          autoFocus
        />
      ) : (
        <p className={styles.sheetBody}>
          You’ll be asked to re-authenticate with{' '}
          {providers.hasGoogle ? 'Google' : 'Apple'} to confirm.
        </p>
      )}
      {error && <p className={styles.sheetError}>{error}</p>}
      <div className={styles.sheetActions}>
        <button type="button" className={styles.cancelButton} onClick={onClose} disabled={busy}>
          Cancel
        </button>
        <button
          type="button"
          className={styles.deleteForeverButton}
          onClick={() => void submit()}
          disabled={busy || (providers.hasPassword && !current)}
        >
          {busy ? 'Deleting…' : 'Delete forever'}
        </button>
      </div>
    </Sheet>
  );
}

// ─── Sheet primitives ─────────────────────────────────────────────────────────

function Sheet({
  title,
  onClose,
  busy = false,
  children,
}: {
  title: string;
  onClose: () => void;
  /** While an op is in flight, no dismiss gesture works (backdrop/Escape) — the
   *  same guard the Cancel button has. Prevents an in-flight submit's success
   *  callback from closing a sheet the user already reopened. */
  busy?: boolean;
  children: React.ReactNode;
}): React.ReactElement {
  const sheetRef = useRef<HTMLDivElement>(null);

  // Escape closes (unless busy); Tab/Shift+Tab cycle within the dialog
  // (aria-modal alone does not trap physical keyboard focus — important for a
  // sensitive auth form).
  const onKeyDown = (e: React.KeyboardEvent): void => {
    if (e.key === 'Escape') {
      if (!busy) onClose();
      return;
    }
    if (e.key !== 'Tab') return;
    const focusable = sheetRef.current?.querySelectorAll<HTMLElement>(
      'a[href], button:not(:disabled), input, textarea, select, [tabindex]:not([tabindex="-1"])',
    );
    if (!focusable || focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  return (
    <div className={styles.backdrop} onClick={busy ? undefined : onClose} role="presentation">
      <div
        ref={sheetRef}
        className={styles.sheet}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(e) => e.stopPropagation()}
        onKeyDown={onKeyDown}
      >
        <h2 className={styles.sheetTitle}>{title}</h2>
        {children}
      </div>
    </div>
  );
}

function Field({
  label,
  type,
  value,
  onChange,
  autoFocus,
}: {
  label: string;
  type: 'password' | 'email' | 'text';
  value: string;
  onChange: (v: string) => void;
  autoFocus?: boolean;
}): React.ReactElement {
  return (
    <label className={styles.field}>
      <span className={styles.fieldLabel}>{label}</span>
      <input
        className={styles.input}
        type={type}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        autoFocus={autoFocus}
      />
    </label>
  );
}

function SheetActions({
  onClose,
  onSubmit,
  busy,
  disabled,
  submitLabel,
}: {
  onClose: () => void;
  onSubmit: () => void;
  busy: boolean;
  disabled: boolean;
  submitLabel: string;
}): React.ReactElement {
  return (
    <div className={styles.sheetActions}>
      <button type="button" className={styles.cancelButton} onClick={onClose} disabled={busy}>
        Cancel
      </button>
      <button
        type="button"
        className={styles.submitButton}
        onClick={onSubmit}
        disabled={busy || disabled}
      >
        {busy ? 'Working…' : submitLabel}
      </button>
    </div>
  );
}
