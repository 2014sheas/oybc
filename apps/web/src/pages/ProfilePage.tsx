import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import type { UserPreferences } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { updateDisplayName } from '../firebase/authService';
import { deleteAccount, friendlyError } from '../firebase/accountSecurity';
import { fetchUser } from '../db/operations';
import { usePreferences } from '../hooks';
import { SyncStatusIndicator } from '../components/SyncStatusIndicator';
import { RisoSegmented, RisoButton } from '../components/riso';
import { UpgradeModal } from '../components/signedOut/UpgradeModal';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — Account info, app-level settings, and sign out.
 *
 * Board-creation defaults (timeframe, size, center type, week-start) live
 * on the Board settings sub-page (`/profile/board-settings`, "New board
 * defaults" section) — they're a related cluster that governs the
 * new-board form and don't belong on the top-level settings surface. (The
 * separate `/profile/board-preferences` sub-page that used to host them was
 * retired; its fields moved into Board settings.)
 */
export function ProfilePage(): React.ReactElement {
  const { user, signOut, isAnonymous } = useAuth();
  const [prefs, updatePrefs] = usePreferences();
  const [showSignOutConfirm, setShowSignOutConfirm] = useState(false);
  const [showUpgradeModal, setShowUpgradeModal] = useState(false);
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const [discardBusy, setDiscardBusy] = useState(false);
  const [discardError, setDiscardError] = useState<string | null>(null);
  const [isEditingName, setIsEditingName] = useState(false);
  const [editNameValue, setEditNameValue] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const nameInputRef = useRef<HTMLInputElement>(null);
  // Track whether the edit was cancelled so onBlur doesn't save
  const cancelledRef = useRef(false);

  // Guest "Discard guest data" (docs/GUEST_MODE.md §Deletion) — routes
  // through the same deleteAccount() as a real account, NOT signOut(), since
  // a plain sign-out would orphan the anonymous Firestore tree. Success is
  // silent: the auth-state listener nils the session and this page unmounts.
  const handleDiscardGuestData = useCallback(async () => {
    setDiscardBusy(true);
    setDiscardError(null);
    try {
      await deleteAccount();
    } catch (err) {
      setDiscardError(friendlyError(err));
      setDiscardBusy(false);
    }
  }, []);

  const saveName = useCallback(async (value: string) => {
    setNameError(null);
    try {
      await updateDisplayName(value);
    } catch (err) {
      setNameError(err instanceof Error ? err.message : 'Failed to update name');
    }
  }, []);

  // Escape-to-close for sign-out / discard-guest-data confirm modals
  // (mutually exclusive — a guest never sees the sign-out modal, and a
  // real account never sees the discard one — but guard each independently).
  useEffect(() => {
    if (!showSignOutConfirm) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setShowSignOutConfirm(false);
    };
    document.addEventListener('keydown', handleKey);
    return () => document.removeEventListener('keydown', handleKey);
  }, [showSignOutConfirm]);

  useEffect(() => {
    if (!showDiscardConfirm || discardBusy) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setShowDiscardConfirm(false);
    };
    document.addEventListener('keydown', handleKey);
    return () => document.removeEventListener('keydown', handleKey);
  }, [showDiscardConfirm, discardBusy]);

  // Read displayName reactively from the Dexie user row so edits show
  // immediately. `useAuth().user` only updates on sign-in/sign-out, not
  // on profile field writes — useLiveQuery fills that gap.
  //
  // When `liveUser` exists, always prefer its displayName (even if
  // undefined = cleared). Only fall back to the auth-context user while
  // the live query is still loading.
  const liveUser = useLiveQuery(
    () => (user?.id ? fetchUser(user.id) : undefined),
    [user?.id]
  );
  // Treat empty string as "no name" — we store '' in Dexie/Firestore
  // for cleared names (undefined gets silently dropped by both).
  const displayName = liveUser
    ? (liveUser.displayName || undefined)
    : (user?.displayName || undefined);

  const displayNameInitial = displayName?.trim().charAt(0).toUpperCase();
  const emailInitial = user?.email?.trim().charAt(0).toUpperCase();
  // Guests have no email (docs/GUEST_MODE.md) — fall back to "G" rather than
  // the generic "?" once a display name is also absent.
  const initial = displayNameInitial || (isAnonymous ? 'G' : emailInitial) || '?';

  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Profile</h1>

      {/* Account card */}
      <div className={styles.card}>
        <div className={styles.accountRow}>
          {user?.photoURL ? (
            <img src={user.photoURL} alt="" className={styles.avatar} />
          ) : (
            <div className={styles.avatarPlaceholder}>{initial}</div>
          )}
          <div className={styles.accountInfo}>
            {isEditingName ? (
              <input
                ref={nameInputRef}
                type="text"
                className={styles.editNameInput}
                aria-label="Display name"
                value={editNameValue}
                onChange={(e) => setEditNameValue(e.target.value)}
                onBlur={() => {
                  if (cancelledRef.current) {
                    cancelledRef.current = false;
                    return;
                  }
                  void saveName(editNameValue);
                  setIsEditingName(false);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    cancelledRef.current = true;
                    void saveName(editNameValue);
                    setIsEditingName(false);
                  } else if (e.key === 'Escape') {
                    cancelledRef.current = true;
                    setIsEditingName(false);
                  }
                }}
                autoFocus
                maxLength={100}
              />
            ) : (
              <button
                type="button"
                className={styles.accountNameButton}
                onClick={() => {
                  setEditNameValue(displayName ?? '');
                  setIsEditingName(true);
                }}
                title="Edit display name"
              >
                <span className={styles.accountName}>
                  {displayName ?? 'OYBC User'}
                </span>
                <span className={styles.editIcon} aria-hidden="true">
                  &#9998;
                </span>
              </button>
            )}
            <span className={styles.accountEmail}>{isAnonymous ? 'Guest' : user?.email}</span>
            {nameError && (
              <span className={styles.nameError}>{nameError}</span>
            )}
          </div>
        </div>
      </div>

      {/* App-level settings */}
      <div className={styles.sectionLabel}>App</div>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <span className={styles.rowLabel}>Theme</span>
          <RisoSegmented<UserPreferences['theme']>
            aria-label="Theme"
            variant="pill"
            value={prefs.theme}
            onChange={(value) => updatePrefs({ theme: value })}
            options={[
              { value: 'system', label: 'System' },
              { value: 'light', label: 'Light' },
              { value: 'dark', label: 'Dark' },
            ]}
          />
        </div>
        <SyncStatusIndicator />
      </div>

      {/* Account management — a guest has no "Account & security" (nothing
          linked yet); the single "Save your account" CTA replaces it and
          opens the upgrade modal (docs/GUEST_MODE.md §In-app guest treatment). */}
      <div className={styles.sectionLabel}>Account</div>
      <div className={styles.card}>
        {isAnonymous ? (
          <div className={styles.saveAccountRow}>
            <p className={styles.saveAccountCopy}>
              You’re using OYBC as a guest. Add a sign-in method to keep your boards, streaks, and
              GREENLOG history — and sync them across every device.
            </p>
            <RisoButton kind="primary" fullWidth onClick={() => setShowUpgradeModal(true)}>
              Save your account
            </RisoButton>
          </div>
        ) : (
          <Link
            to="/profile/account-security"
            className={`${styles.settingsRow} ${styles.rowLink}`}
          >
            <span className={styles.rowLabel}>Account &amp; security</span>
            <span className={styles.rowArrow}>&rarr;</span>
          </Link>
        )}
      </div>

      {/* Activity */}
      <div className={styles.sectionLabel}>Activity</div>
      <div className={styles.card}>
        <Link
          to="/profile/streaks"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Streaks</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
        <Link
          to="/profile/counters"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Shared counters</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
      </div>

      {/* Preferences sub-pages */}
      <div className={styles.sectionLabel}>Preferences</div>
      <div className={styles.card}>
        <Link
          to="/profile/board-settings"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Board settings</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
      </div>

      {/* Developer tools — dev builds only. The Playground can wipe the real
          local database, so this section (and the route it links to) must
          not be reachable in production. */}
      {import.meta.env.DEV && (
        <>
          <div className={styles.sectionLabel}>Developer</div>
          <div className={styles.card}>
            <Link to="/playground" className={`${styles.settingsRow} ${styles.rowLink}`}>
              <span className={styles.rowLabel}>Playground</span>
              <span className={styles.rowArrow}>&rarr;</span>
            </Link>
          </div>
        </>
      )}

      {/* Sign out — a guest gets the destructive "Discard guest data" in its
          place (docs/GUEST_MODE.md §Deletion); a plain sign-out would orphan
          the anonymous Firestore tree with no way back in. */}
      {isAnonymous ? (
        <button
          type="button"
          className={styles.signOutButton}
          onClick={() => setShowDiscardConfirm(true)}
        >
          Discard guest data
        </button>
      ) : (
        <button
          type="button"
          className={styles.signOutButton}
          onClick={() => setShowSignOutConfirm(true)}
        >
          Sign Out
        </button>
      )}

      {/* Version footer — mirrors iOS ProfileView "OYBC · v{version} ({build})" footer.
          Web has no build number (no bundle metadata at runtime), so we show semver only.
          Version is injected at build time from package.json via vite.config.ts `define`. */}
      <p className={styles.versionFooter}>
        OYBC · v{__APP_VERSION__}
      </p>

      {/* Sign-out confirmation modal */}
      {showSignOutConfirm && (
        <div
          className={styles.confirmBackdrop}
          onClick={() => setShowSignOutConfirm(false)}
        >
          <div
            className={styles.confirmModal}
            onClick={(e) => e.stopPropagation()}
            role="dialog"
            aria-modal="true"
            aria-labelledby="sign-out-title"
          >
            <h2 id="sign-out-title" className={styles.confirmTitle}>
              Sign out?
            </h2>
            <p className={styles.confirmBody}>
              Are you sure you want to sign out?
            </p>
            <div className={styles.confirmActions}>
              <button
                type="button"
                className={styles.confirmCancel}
                onClick={() => setShowSignOutConfirm(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className={styles.confirmDestructive}
                onClick={() => void signOut()}
              >
                Sign Out
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Discard-guest-data confirmation modal (docs/GUEST_MODE.md §Deletion) —
          routes through deleteAccount(), never signOut(). Success is silent:
          the auth-state listener nils the session and this page unmounts, so
          `discardBusy` is only ever reset on failure (mirrors DeleteAccountSheet). */}
      {showDiscardConfirm && (
        <div
          className={styles.confirmBackdrop}
          onClick={() => !discardBusy && setShowDiscardConfirm(false)}
        >
          <div
            className={styles.confirmModal}
            onClick={(e) => e.stopPropagation()}
            role="dialog"
            aria-modal="true"
            aria-labelledby="discard-guest-title"
          >
            <h2 id="discard-guest-title" className={styles.confirmTitle}>
              Discard guest data?
            </h2>
            <p className={styles.confirmBody}>
              This permanently erases every board, streak, and GREENLOG on this device. Guest data
              isn’t backed up to an account, so this can’t be undone.
            </p>
            {discardError && <p className={styles.nameError}>{discardError}</p>}
            <div className={styles.confirmActions}>
              <button
                type="button"
                className={styles.confirmCancel}
                onClick={() => setShowDiscardConfirm(false)}
                disabled={discardBusy}
              >
                Cancel
              </button>
              <button
                type="button"
                className={styles.confirmDestructive}
                onClick={() => void handleDiscardGuestData()}
                disabled={discardBusy}
              >
                {discardBusy ? 'Discarding…' : 'Discard forever'}
              </button>
            </div>
          </div>
        </div>
      )}

      {showUpgradeModal && <UpgradeModal onClose={() => setShowUpgradeModal(false)} />}
    </div>
  );
}
