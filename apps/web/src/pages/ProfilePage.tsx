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

  const initial = user?.displayName?.charAt(0).toUpperCase()
    ?? user?.email?.charAt(0).toUpperCase()
    ?? '?';

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
          <div className={styles.toggleGroup} role="radiogroup" aria-label="Theme">
            <button
              type="button"
              role="radio"
              aria-checked={theme === 'light'}
              className={`${styles.toggleBtn} ${theme === 'light' ? styles.toggleBtnActive : ''}`}
              onClick={() => theme !== 'light' && onThemeToggle()}
            >
              Light
            </button>
            <button
              type="button"
              role="radio"
              aria-checked={theme === 'dark'}
              className={`${styles.toggleBtn} ${theme === 'dark' ? styles.toggleBtnActive : ''}`}
              onClick={() => theme !== 'dark' && onThemeToggle()}
            >
              Dark
            </button>
          </div>
        </div>
        <div className={styles.settingsRow}>
          <span className={styles.rowLabel}>Last synced</span>
          <span className={styles.rowValue}>
            {lastSyncedAt
              ? new Date(lastSyncedAt).toLocaleTimeString()
              : 'Never'}
          </span>
        </div>
        <div className={styles.settingsRow}>
          <Link to="/playground" className={styles.rowLink}>
            <span className={styles.rowLabel}>Playground</span>
            <span className={styles.rowArrow}>&rarr;</span>
          </Link>
        </div>
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
