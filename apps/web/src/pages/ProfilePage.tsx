import { useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import type { UserPreferences } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { updateDisplayName } from '../firebase/authService';
import { db } from '../db/database';
import { usePreferences } from '../hooks';
import { SyncStatusIndicator } from '../components/SyncStatusIndicator';
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
  const nameInputRef = useRef<HTMLInputElement>(null);

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
                value={editNameValue}
                onChange={(e) => setEditNameValue(e.target.value)}
                onBlur={() => {
                  void updateDisplayName(editNameValue);
                  setIsEditingName(false);
                }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    void updateDisplayName(editNameValue);
                    setIsEditingName(false);
                  } else if (e.key === 'Escape') {
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
          </div>
        </div>
      </div>

      {/* App-level settings */}
      <div className={styles.sectionLabel}>App</div>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-theme">
            Theme
          </label>
          <select
            id="pref-theme"
            className={styles.select}
            value={prefs.theme}
            onChange={(e) =>
              updatePrefs({ theme: e.target.value as UserPreferences['theme'] })
            }
          >
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>
        <SyncStatusIndicator />
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
      </div>

      {/* Developer tools */}
      <div className={styles.sectionLabel}>Developer</div>
      <div className={styles.card}>
        <Link to="/playground" className={`${styles.settingsRow} ${styles.rowLink}`}>
          <span className={styles.rowLabel}>Playground</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
      </div>

      {/* Sign out */}
      <button
        type="button"
        className={styles.signOutButton}
        onClick={() => setShowSignOutConfirm(true)}
      >
        Sign Out
      </button>

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
