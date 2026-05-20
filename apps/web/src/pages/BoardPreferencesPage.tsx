import { useEffect, useState } from 'react';
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

  // Free-form text fields keep a local draft so every keystroke doesn't
  // bump `version` and enqueue a sync item. The draft commits on blur or
  // Enter, and resyncs if the value changes externally (e.g. a pull from
  // another device).
  const [centerCustomNameDraft, setCenterCustomNameDraft] = useState(
    prefs.defaultCenterCustomName
  );
  useEffect(() => {
    setCenterCustomNameDraft(prefs.defaultCenterCustomName);
  }, [prefs.defaultCenterCustomName]);

  const commitCenterCustomName = (): void => {
    const trimmed = centerCustomNameDraft;
    if (trimmed !== prefs.defaultCenterCustomName) {
      set('defaultCenterCustomName', trimmed);
    }
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
            value={centerCustomNameDraft}
            maxLength={100}
            placeholder='e.g., "Wild Card"'
            onChange={(e) => setCenterCustomNameDraft(e.target.value)}
            onBlur={commitCenterCustomName}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.currentTarget.blur();
              }
            }}
          />
        </div>
      </div>

      {/* Recurring boards (Phase 6.1) — independent of the defaults above
       *  because these toggles drive the Boards-tab banner, not new-board
       *  defaults. When enabled, the Boards tab prompts the user to
       *  create a board for each new window (daily/weekly/monthly/yearly)
       *  on first open inside that window. */}
      <h2 className={styles.header} style={{ fontSize: 20, paddingTop: 8 }}>
        Recurring boards
      </h2>
      <p className={styles.subPageIntro}>
        When enabled, the Boards tab will prompt you to create a board for
        each new window. Detection runs only when you open the app — no
        background notifications.
      </p>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-recurring-daily">
            Prompt for daily board
          </label>
          <label className={styles.toggleSwitch}>
            <input
              id="pref-recurring-daily"
              type="checkbox"
              checked={prefs.recurringDailyEnabled}
              onChange={(e) => set('recurringDailyEnabled', e.target.checked)}
            />
            <span className={styles.toggleTrack} />
          </label>
          {prefs.recurringDailyEnabled && (
            <Link to={`/boards/core/${Timeframe.DAILY}`} className={styles.browseLink}>
              Browse →
            </Link>
          )}
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-recurring-weekly">
            Prompt for weekly board
          </label>
          <label className={styles.toggleSwitch}>
            <input
              id="pref-recurring-weekly"
              type="checkbox"
              checked={prefs.recurringWeeklyEnabled}
              onChange={(e) => set('recurringWeeklyEnabled', e.target.checked)}
            />
            <span className={styles.toggleTrack} />
          </label>
          {prefs.recurringWeeklyEnabled && (
            <Link to={`/boards/core/${Timeframe.WEEKLY}`} className={styles.browseLink}>
              Browse →
            </Link>
          )}
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-recurring-monthly">
            Prompt for monthly board
          </label>
          <label className={styles.toggleSwitch}>
            <input
              id="pref-recurring-monthly"
              type="checkbox"
              checked={prefs.recurringMonthlyEnabled}
              onChange={(e) => set('recurringMonthlyEnabled', e.target.checked)}
            />
            <span className={styles.toggleTrack} />
          </label>
          {prefs.recurringMonthlyEnabled && (
            <Link to={`/boards/core/${Timeframe.MONTHLY}`} className={styles.browseLink}>
              Browse →
            </Link>
          )}
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-recurring-yearly">
            Prompt for yearly board
          </label>
          <label className={styles.toggleSwitch}>
            <input
              id="pref-recurring-yearly"
              type="checkbox"
              checked={prefs.recurringYearlyEnabled}
              onChange={(e) => set('recurringYearlyEnabled', e.target.checked)}
            />
            <span className={styles.toggleTrack} />
          </label>
          {prefs.recurringYearlyEnabled && (
            <Link to={`/boards/core/${Timeframe.YEARLY}`} className={styles.browseLink}>
              Browse →
            </Link>
          )}
        </div>
      </div>
    </div>
  );
}
