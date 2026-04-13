import { useLiveQuery } from 'dexie-react-hooks';
import { Link } from 'react-router-dom';
import {
  CenterSquareType,
  Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { useAuth } from '../firebase/AuthContext';
import { db } from '../db/database';
import { usePreferences } from '../hooks';
import styles from './ProfilePage.module.css';

/**
 * ProfilePage — Account info, synced preferences, and sign out.
 *
 * Every control here reads from and writes to the user's synced
 * `preferences` object via `usePreferences()`, so changes replicate to
 * other devices through the standard sync queue.
 */
export function ProfilePage(): React.ReactElement {
  const { user, signOut } = useAuth();
  const [prefs, updatePrefs] = usePreferences();

  const displayNameInitial = user?.displayName?.trim().charAt(0).toUpperCase();
  const emailInitial = user?.email?.trim().charAt(0).toUpperCase();
  const initial = displayNameInitial || emailInitial || '?';

  // Live query for lastSyncedAt — auth context doesn't update when sync writes to DB.
  const liveUser = useLiveQuery(
    () => (user ? db.users.get(user.id) : undefined),
    [user?.id]
  );
  const lastSyncedAt = liveUser?.lastSyncedAt;

  // ── Typed setters per preference field ─────────────────────────────────
  // Wrapping `updatePrefs` lets TS narrow the value type at each call site
  // and keeps the JSX below compact.
  const set = <K extends keyof UserPreferences>(
    key: K,
    value: UserPreferences[K]
  ): void => {
    updatePrefs({ [key]: value } as Partial<UserPreferences>);
  };

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

      {/* App card */}
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
            onChange={(e) => set('theme', e.target.value as UserPreferences['theme'])}
          >
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>
        <div className={styles.settingsRow}>
          <span className={styles.rowLabel}>Last synced</span>
          <span className={styles.rowValue}>
            {lastSyncedAt ? new Date(lastSyncedAt).toLocaleTimeString() : 'Never'}
          </span>
        </div>
        <Link to="/playground" className={`${styles.settingsRow} ${styles.rowLink}`}>
          <span className={styles.rowLabel}>Playground</span>
          <span className={styles.rowArrow}>&rarr;</span>
        </Link>
      </div>

      {/* Board defaults card */}
      <div className={styles.sectionLabel}>Board Defaults</div>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-week-start">
            Week starts on
          </label>
          <select
            id="pref-week-start"
            className={styles.select}
            value={prefs.weekStartDay}
            onChange={(e) =>
              set('weekStartDay', e.target.value as UserPreferences['weekStartDay'])
            }
          >
            <option value="monday">Monday</option>
            <option value="sunday">Sunday</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-board-size">
            Default board size
          </label>
          <select
            id="pref-board-size"
            className={styles.select}
            value={prefs.defaultBoardSize}
            onChange={(e) =>
              set('defaultBoardSize', Number(e.target.value) as UserPreferences['defaultBoardSize'])
            }
          >
            <option value={3}>3 × 3</option>
            <option value={4}>4 × 4</option>
            <option value={5}>5 × 5</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-timeframe">
            Default timeframe
          </label>
          <select
            id="pref-timeframe"
            className={styles.select}
            value={prefs.defaultTimeframe}
            onChange={(e) => set('defaultTimeframe', e.target.value as Timeframe)}
          >
            <option value={Timeframe.CUSTOM}>Custom</option>
            <option value={Timeframe.DAILY}>Daily</option>
            <option value={Timeframe.WEEKLY}>Weekly</option>
            <option value={Timeframe.MONTHLY}>Monthly</option>
            <option value={Timeframe.YEARLY}>Yearly</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-center-type">
            Default center square
          </label>
          <select
            id="pref-center-type"
            className={styles.select}
            value={prefs.defaultCenterType}
            onChange={(e) =>
              set('defaultCenterType', e.target.value as UserPreferences['defaultCenterType'])
            }
          >
            <option value={CenterSquareType.FREE}>Free</option>
            <option value={CenterSquareType.NONE}>None</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-randomize">
            Randomize tasks by default
          </label>
          <label className={styles.toggleSwitch}>
            <input
              id="pref-randomize"
              type="checkbox"
              checked={prefs.defaultRandomize}
              onChange={(e) => set('defaultRandomize', e.target.checked)}
            />
            <span className={styles.toggleTrack} />
          </label>
        </div>

        <div className={styles.stackedRow}>
          <label className={styles.rowLabel} htmlFor="pref-center-custom-name">
            Default custom center name
          </label>
          <input
            id="pref-center-custom-name"
            type="text"
            className={styles.textInput}
            value={prefs.defaultCenterCustomName}
            maxLength={100}
            placeholder='e.g., "Wild Card"'
            onChange={(e) => set('defaultCenterCustomName', e.target.value)}
          />
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
