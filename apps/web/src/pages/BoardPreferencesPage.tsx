import { Link } from 'react-router-dom';
import {
  CenterSquareType,
  Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { usePreferences } from '../hooks';
import styles from './ProfilePage.module.css';

/**
 * BoardPreferencesPage — Sub-page of Profile for board-creation defaults.
 *
 * Split out from the top-level Profile page so the primary settings surface
 * stays focused on account + app-level controls; every control here governs
 * a field on the new-board form and belongs together.
 */
export function BoardPreferencesPage(): React.ReactElement {
  const [prefs, updatePrefs] = usePreferences();

  const set = <K extends keyof UserPreferences>(
    key: K,
    value: UserPreferences[K]
  ): void => {
    updatePrefs({ [key]: value } as Partial<UserPreferences>);
  };

  return (
    <div className={styles.container}>
      <div className={styles.subPageHeader}>
        <Link to="/profile" className={styles.backLink} aria-label="Back to Profile">
          &larr;
        </Link>
        <h1 className={styles.header}>Board Preferences</h1>
      </div>

      <p className={styles.subPageIntro}>
        These defaults apply to new boards you create. You can override any of
        them on a per-board basis.
      </p>

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
              set(
                'defaultBoardSize',
                Number(e.target.value) as UserPreferences['defaultBoardSize']
              )
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
              set(
                'defaultCenterType',
                e.target.value as UserPreferences['defaultCenterType']
              )
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
    </div>
  );
}
