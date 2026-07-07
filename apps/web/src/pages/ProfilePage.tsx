import { useCallback, useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import type { UserPreferences } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { updateDisplayName } from '../firebase/authService';
import { db } from '../db/database';
import { usePreferences } from '../hooks';
import { SyncStatusIndicator } from '../components/SyncStatusIndicator';
import { RisoSegmented } from '../components/riso';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — Account info, app-level settings, and sign out.
 *
 * Board-creation defaults (timeframe, size, center type, randomize, custom
 * center name, week-start) live in a dedicated sub-page at
 * `/profile/board-preferences` — they're a related cluster that governs the
 * new-board form and don't belong on the top-level settings surface.
 */
export function ProfilePage(): React.ReactElement {
  const { user, signOut } = useAuth();
  const [prefs, updatePrefs] = usePreferences();
  const [showSignOutConfirm, setShowSignOutConfirm] = useState(false);
  const [isEditingName, setIsEditingName] = useState(false);
  const [editNameValue, setEditNameValue] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const nameInputRef = useRef<HTMLInputElement>(null);
  // Track whether the edit was cancelled so onBlur doesn't save
  const cancelledRef = useRef(false);

  const saveName = useCallback(async (value: string) => {
    setNameError(null);
    try {
      await updateDisplayName(value);
    } catch (err) {
      setNameError(err instanceof Error ? err.message : 'Failed to update name');
    }
  }, []);

  // Escape-to-close for sign-out modal
  useEffect(() => {
    if (!showSignOutConfirm) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setShowSignOutConfirm(false);
    };
    document.addEventListener('keydown', handleKey);
    return () => document.removeEventListener('keydown', handleKey);
  }, [showSignOutConfirm]);

  // Read displayName reactively from the Dexie user row so edits show
  // immediately. `useAuth().user` only updates on sign-in/sign-out, not
  // on profile field writes — useLiveQuery fills that gap.
  //
  // When `liveUser` exists, always prefer its displayName (even if
  // undefined = cleared). Only fall back to the auth-context user while
  // the live query is still loading.
  const liveUser = useLiveQuery(
    () => (user?.id ? db.users.get(user.id) : undefined),
    [user?.id]
  );
  // Treat empty string as "no name" — we store '' in Dexie/Firestore
  // for cleared names (undefined gets silently dropped by both).
  const displayName = liveUser
    ? (liveUser.displayName || undefined)
    : (user?.displayName || undefined);

  const displayNameInitial = displayName?.trim().charAt(0).toUpperCase();
  const emailInitial = user?.email?.trim().charAt(0).toUpperCase();
  const initial = displayNameInitial || emailInitial || '?';

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
            <span className={styles.accountEmail}>{user?.email}</span>
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

      {/* Account management */}
      <div className={styles.sectionLabel}>Account</div>
      <div className={styles.card}>
        <Link
          to="/profile/account-security"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Account &amp; security</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
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
          to="/profile/board-preferences"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Board preferences</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
        <Link
          to="/profile/recurring-templates"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Recurring templates</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
        <Link
          to="/profile/default-pools"
          className={`${styles.settingsRow} ${styles.rowLink}`}
        >
          <span className={styles.rowLabel}>Default pools</span>
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

      {/* Sign out */}
      <button
        type="button"
        className={styles.signOutButton}
        onClick={() => setShowSignOutConfirm(true)}
      >
        Sign Out
      </button>

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
    </div>
  );
}
