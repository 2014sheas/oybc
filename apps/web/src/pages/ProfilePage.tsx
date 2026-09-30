import { useCallback, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../firebase/useAuth';
import { updateDisplayName } from '../firebase/authService';
import { fetchUser } from '../db/operations';
import { RisoIcon } from '../components/riso';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — Account info and quick links (Streaks, Shared counters,
 * Board settings). Everything touched rarely (Theme, Account & security,
 * Help & getting started, Board renewals, Developer, Sign Out) now lives
 * behind the Settings pill button, at `/profile/settings` (Profile reorg
 * PR1, `design_handoff_profile_reorg/README.md`). PR2 rebuilds the rest of
 * this page's home-surface layout (tiles, tutorial row/hero, counters
 * block) — this pass only removes what moved and adds the entry point.
 *
 * Board-creation defaults (timeframe, size, center type, week-start) live
 * on the Board settings sub-page (`/profile/board-settings`, "New board
 * defaults" section) — they're a related cluster that governs the
 * new-board form and don't belong on the top-level settings surface. (The
 * separate `/profile/board-preferences` sub-page that used to host them was
 * retired; its fields moved into Board settings.)
 */
export function ProfilePage(): React.ReactElement {
  const { user, isAnonymous } = useAuth();
  const navigate = useNavigate();
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
      <div className={styles.pageHeader}>
        <h1 className={styles.header}>Profile</h1>
        <button
          type="button"
          className={styles.settingsButton}
          onClick={() => navigate('/profile/settings')}
          aria-label="Settings"
        >
          <RisoIcon name="sliders" size={16} />
          <span className={styles.settingsButtonLabel}>Settings</span>
        </button>
      </div>

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
    </div>
  );
}
