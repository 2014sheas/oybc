import { Link } from 'react-router-dom';
import {
  CenterSquareType,
  Timeframe,
  type UserPreferences,
} from '@oybc/shared';
import { usePreferences } from '../hooks';
import styles from './ProfilePage.module.css';

/**
 * Human-readable label for a celebration intensity value.
 * Mirrors the iOS BoardPreferencesView.intensityWord() mapping exactly.
 */
function intensityWord(v: number): string {
  if (v <= 2) return 'Whisper';
  if (v <= 4) return 'Quiet';
  if (v <= 6) return 'Steady';
  if (v <= 8) return 'Full press';
  if (v === 9) return 'Loud';
  return 'Detonate';
}

/**
 * Background and border color for a single intensity tick.
 *
 * iOS mapping:
 *   - ticks 1–7, active  → gold fill + ink-static border
 *   - ticks 8–10, active → red fill + ink-static border
 *   - inactive            → paper-2 fill + adaptive ink border
 */
function tickStyle(tick: number, current: number): React.CSSProperties {
  if (tick <= current) {
    const bg = tick >= 8 ? 'var(--riso-red)' : 'var(--riso-gold)';
    // Colored fill → border must be ink-static (dark-mode contract).
    return { background: bg, borderColor: 'var(--riso-ink-static)' };
  }
  // Paper fill → adaptive ink border is the safe pair.
  return { background: 'var(--riso-paper-2)', borderColor: 'var(--riso-ink)' };
}

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
      </div>

      {/* Playing card — celebration intensity (parity with iOS "Playing" card) */}
      <h2 className={styles.sectionLabel} style={{ marginTop: 8 }}>
        Playing
      </h2>
      <div className={styles.card}>
        <div className={styles.stackedRow}>
          <div className={styles.intensityHeader}>
            <span className={styles.intensityLabel}>
              <span className={styles.intensityLabelIcon} aria-hidden="true">✦</span>
              Celebration intensity
            </span>
            <span className={styles.intensityValue}>
              {prefs.celebrationIntensity} · {intensityWord(prefs.celebrationIntensity)}
            </span>
          </div>
          {/* 10-tick strip. Mirrors iOS intensityStrip exactly: gold for 1–7,
              red for 8–10 when at or below current; paper otherwise. */}
          <div className={styles.intensityStrip} role="group" aria-label="Celebration intensity">
            {Array.from({ length: 10 }, (_, i) => i + 1).map((tick) => (
              <button
                key={tick}
                type="button"
                className={styles.intensityTick}
                style={tickStyle(tick, prefs.celebrationIntensity)}
                aria-label={`Intensity ${tick}: ${intensityWord(tick)}`}
                aria-pressed={tick === prefs.celebrationIntensity}
                onClick={() => set('celebrationIntensity', tick)}
              />
            ))}
          </div>
          <p className={styles.intensityCaption}>
            How loud bingos and GREENLOGs get — confetti scales with it.
          </p>
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
