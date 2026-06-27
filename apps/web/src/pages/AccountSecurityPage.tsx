import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../firebase/useAuth';
import { db } from '../db/database';
import {
  EMPTY_PROVIDER_STATE,
  getProviderState,
  isRecentLoginRequired,
  linkPassword,
  reauthWithPassword,
  reconcileEmailIfChanged,
  sendPasswordResetToCurrentUser,
  updateAccountEmail,
  updateAccountPassword,
  type ProviderState,
} from '../firebase/accountSecurity';
import styles from './AccountSecurityPage.module.css';

/** Which action sheet is open (Sign-in section — Phase 5b-i). */
type SheetMode = 'changeEmail' | 'changePassword' | 'addPassword' | null;

/**
 * Account & security (Phase 5b, web). Net-new screen mirroring iOS §5c. This
 * sub-PR (5b-i) ships the **Sign in** section: view email, change email /
 * password (password users), or add a password (OAuth-only accounts). Provider
 * link/unlink (5b-ii) and account deletion (5b-iii) land in later sub-PRs.
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
    </div>
  );
}

// ─── Sheets ───────────────────────────────────────────────────────────────────

/** Map a Firebase/Error to a user-facing string (never a raw provider code). */
function friendlyError(err: unknown): string {
  if (isRecentLoginRequired(err)) {
    return 'For your security, the current password didn’t match or your session is stale. Re-enter it and try again.';
  }
  const code = (err as { code?: string } | undefined)?.code;
  if (code === 'auth/wrong-password' || code === 'auth/invalid-credential') {
    return 'That current password is incorrect.';
  }
  if (code === 'auth/weak-password') return 'Pick a stronger password (at least 6 characters).';
  if (code === 'auth/email-already-in-use') return 'That email is already in use by another account.';
  if (code === 'auth/invalid-email') return 'That email address looks invalid.';
  return 'Something went wrong. Please try again.';
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
    <Sheet title="Change password" onClose={onClose}>
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
    <Sheet title="Change email" onClose={onClose}>
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
    <Sheet title="Add a password" onClose={onClose}>
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

// ─── Sheet primitives ─────────────────────────────────────────────────────────

function Sheet({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: React.ReactNode;
}): React.ReactElement {
  const sheetRef = useRef<HTMLDivElement>(null);

  // Escape closes; Tab/Shift+Tab cycle within the dialog (aria-modal alone does
  // not trap physical keyboard focus — important for a sensitive auth form).
  const onKeyDown = (e: React.KeyboardEvent): void => {
    if (e.key === 'Escape') {
      onClose();
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
    <div className={styles.backdrop} onClick={onClose} role="presentation">
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
