import {
  CenterSquareType,
  Timeframe,
  type BoardSize,
  type UserPreferences,
} from '@oybc/shared';
import { RisoSegmented, type RisoSegmentedOption } from '../riso';
import styles from './EveryNewBoardCard.module.css';

const SIZE_OPTIONS: ReadonlyArray<RisoSegmentedOption<BoardSize>> = [
  { value: 3, label: '3×3' },
  { value: 4, label: '4×4' },
  { value: 5, label: '5×5' },
];

const TIMEFRAME_OPTIONS: ReadonlyArray<RisoSegmentedOption<Timeframe>> = [
  { value: Timeframe.CUSTOM, label: 'Custom' },
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

const CENTER_OPTIONS: ReadonlyArray<RisoSegmentedOption<UserPreferences['defaultCenterType']>> = [
  { value: CenterSquareType.FREE, label: 'Free' },
  { value: CenterSquareType.NONE, label: 'None' },
];

const WEEK_START_OPTIONS: ReadonlyArray<RisoSegmentedOption<UserPreferences['weekStartDay']>> = [
  { value: 'monday', label: 'Mon' },
  { value: 'sunday', label: 'Sun' },
];

export interface EveryNewBoardCardProps {
  preferences: UserPreferences;
  onChange: <K extends keyof UserPreferences>(key: K, value: UserPreferences[K]) => void;
}

/**
 * "EVERY NEW BOARD" card — Board settings' first group (Profile reorg PR3,
 * `design_handoff_profile_reorg/README.md` §4 / screenshot `4c-board-settings.png`):
 * Size / Timeframe / Center square / Week starts, all writing the same
 * `UserPreferences` fields the page always has (formerly plain `<select>`s
 * under the "New board defaults" heading). Extracted from `BoardSettingsPage`
 * to keep that file under the repo's 1000-line file-size ceiling.
 *
 * Size / Center square / Week starts are compact, right-aligned
 * `RisoSegmented` rows (2–3 options each, natural width). Timeframe is the
 * one 5-option row and must span the card full-width without wrapping even
 * at a 393px viewport — `RisoSegmented`'s `fullWidth` + `size="compact"`
 * combination (see `RisoSegmented.module.css`).
 */
export function EveryNewBoardCard({ preferences, onChange }: EveryNewBoardCardProps): React.ReactElement {
  return (
    <div className={styles.card}>
      <div className={styles.inlineRow}>
        <span className={styles.rowLabel}>Size</span>
        <RisoSegmented<BoardSize>
          aria-label="Default board size"
          options={SIZE_OPTIONS}
          value={preferences.defaultBoardSize}
          onChange={(value) => onChange('defaultBoardSize', value)}
          size="compact"
        />
      </div>

      <div className={styles.stackedRow}>
        <span className={styles.rowLabel}>Timeframe</span>
        <RisoSegmented<Timeframe>
          aria-label="Default timeframe"
          options={TIMEFRAME_OPTIONS}
          value={preferences.defaultTimeframe}
          onChange={(value) => onChange('defaultTimeframe', value)}
          size="compact"
          fullWidth
        />
      </div>

      <div className={styles.inlineRow}>
        <span className={styles.rowLabel}>Center square</span>
        <RisoSegmented<UserPreferences['defaultCenterType']>
          aria-label="Default center square"
          options={CENTER_OPTIONS}
          value={preferences.defaultCenterType}
          onChange={(value) => onChange('defaultCenterType', value)}
          size="compact"
        />
      </div>

      <div className={styles.inlineRow}>
        <span className={styles.rowLabel}>Week starts</span>
        <RisoSegmented<UserPreferences['weekStartDay']>
          aria-label="Week starts on"
          options={WEEK_START_OPTIONS}
          value={preferences.weekStartDay}
          onChange={(value) => onChange('weekStartDay', value)}
          size="compact"
        />
      </div>
    </div>
  );
}
