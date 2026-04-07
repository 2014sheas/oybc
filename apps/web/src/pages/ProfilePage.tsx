import { useLiveQuery } from 'dexie-react-hooks';
import { useAuth } from '../firebase/AuthContext';
import { db } from '../db/database';
import { Link } from 'react-router-dom';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — User info, app settings, and sign out.
 *
 * Grouped card layout matching iOS Settings pattern.
 * Theme toggle, sync status, playground link, sign out.
 */
export function ProfilePage({
  theme,
  onThemeToggle,
}: {
  theme: 'light' | 'dark';
  onThemeToggle: () => void;
}): React.ReactElement {
  const { user, signOut } = useAuth();

  const displayNameInitial = user?.displayName?.trim().charAt(0).toUpperCase();
  const emailInitial = user?.email?.trim().charAt(0).toUpperCase();
  const initial = displayNameInitial || emailInitial || '?';

  // Live query for lastSyncedAt — auth context doesn't update when sync writes to DB
  const liveUser = useLiveQuery(
    () => user ? db.users.get(user.id) : undefined,
    [user?.id]
  );
  const lastSyncedAt = liveUser?.lastSyncedAt;

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
            <span className={styles.accountName}>
              {user?.displayName ?? 'OYBC User'}
            </span>
            <span className={styles.accountEmail}>{user?.email}</span>
          </div>
        </div>
      </div>

      {/* App settings card */}
      <div className={styles.sectionLabel}>App</div>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <span className={styles.rowLabel}>Theme</span>
          <fieldset className={styles.toggleGroup}>
            <legend className={styles.srOnly}>Theme</legend>
            <label className={`${styles.toggleBtn} ${theme === 'light' ? styles.toggleBtnActive : ''}`}>
              <input
                type="radio"
                name="theme"
                value="light"
                checked={theme === 'light'}
                onChange={() => theme !== 'light' && onThemeToggle()}
                className={styles.srOnly}
              />
              Light
            </label>
            <label className={`${styles.toggleBtn} ${theme === 'dark' ? styles.toggleBtnActive : ''}`}>
              <input
                type="radio"
                name="theme"
                value="dark"
                checked={theme === 'dark'}
                onChange={() => theme !== 'dark' && onThemeToggle()}
                className={styles.srOnly}
              />
              Dark
            </label>
          </fieldset>
        </div>
        <div className={styles.settingsRow}>
          <span className={styles.rowLabel}>Last synced</span>
          <span className={styles.rowValue}>
            {lastSyncedAt
              ? new Date(lastSyncedAt).toLocaleTimeString()
              : 'Never'}
          </span>
        </div>
        <Link to="/playground" className={`${styles.settingsRow} ${styles.rowLink}`}>
          <span className={styles.rowLabel}>Playground</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
      </div>

      {/* Sign out */}
      <button
        type="button"
        className={styles.signOutButton}
        onClick={() => void signOut()}
      >
        Sign Out
      </button>
    </div>
  );
}
