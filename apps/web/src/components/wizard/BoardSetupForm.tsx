import {
  CenterSquareType,
  Timeframe,
  formatRecurringCadence,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  type WeekStartDay,
} from "@oybc/shared";
import styles from "./BoardSetupForm.module.css";

const SIZE_OPTIONS: { value: 3 | 4 | 5; label: string }[] = [
  { value: 3, label: "3×3" },
  { value: 4, label: "4×4" },
  { value: 5, label: "5×5" },
];

const TIMEFRAME_OPTIONS: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: "Daily" },
  { value: Timeframe.WEEKLY, label: "Weekly" },
  { value: Timeframe.MONTHLY, label: "Monthly" },
  { value: Timeframe.YEARLY, label: "Yearly" },
  { value: Timeframe.CUSTOM, label: "Custom" },
];

/** Subset of `TIMEFRAME_OPTIONS` shown when `isRecurring=true`. The
 *  recurring template schema rejects `Timeframe.CUSTOM` (no computed
 *  window), so the form hides it. */
const RECURRING_TIMEFRAME_OPTIONS = TIMEFRAME_OPTIONS.filter(
  (o) => o.value !== Timeframe.CUSTOM,
);

const CENTER_TYPE_OPTIONS: { value: CenterSquareType; label: string }[] = [
  { value: CenterSquareType.FREE, label: "Free Space" },
  { value: CenterSquareType.CUSTOM_FREE, label: "Custom Name" },
  { value: CenterSquareType.CHOSEN, label: "Pick one of my board tasks" },
  { value: CenterSquareType.NONE, label: "None" },
];

/** Subset of `CENTER_TYPE_OPTIONS` shown when `isRecurring=true`. The
 *  recurring template MVP excludes `CenterSquareType.CHOSEN` — adding
 *  a per-template `centerTaskId` is a future extension. */
const RECURRING_CENTER_TYPE_OPTIONS = CENTER_TYPE_OPTIONS.filter(
  (o) => o.value !== CenterSquareType.CHOSEN,
);

export interface BoardSetupFormProps {
  // Controlled state
  name: string;
  onNameChange: (v: string) => void;

  size: 3 | 4 | 5;
  onSizeChange: (s: 3 | 4 | 5) => void;

  timeframe: Timeframe;
  onTimeframeChange: (t: Timeframe) => void;
  /** When true, the timeframe is rendered as a read-only chip (no
   *  segmented selector). Used by the recurring-banner flow (Phase
   *  6.1) so the user can't accidentally pick a different timeframe
   *  than the banner promised. */
  timeframeLocked?: boolean;

  customStartDate: string;
  onCustomStartDateChange: (d: string) => void;
  customEndDate: string;
  onCustomEndDateChange: (d: string) => void;

  centerType: CenterSquareType;
  onCenterTypeChange: (t: CenterSquareType) => void;
  centerCustomName: string;
  onCenterCustomNameChange: (n: string) => void;

  isRandomized: boolean;
  onIsRandomizedChange: (b: boolean) => void;

  /** Phase 6.2 — when true, the wizard saves a recurring template
   *  (and immediately spawns the current window's board) instead of
   *  a one-off Board. Toggling hides Custom from the timeframe
   *  selector (recurring schema rejects it). */
  isRecurring: boolean;
  onIsRecurringChange: (b: boolean) => void;

  weekStartDay: WeekStartDay;
}

/**
 * BoardSetupForm — Pure presentational form for the wizard's Setup step.
 *
 * Renders all configuration controls (name, size, timeframe, custom
 * dates, center type, custom name input, randomize toggle) without
 * owning any state. The wizard controller drives every field via the
 * `on*Change` callbacks.
 *
 * Center-type options for odd boards include the renamed
 * "Pick one of my board tasks" (formerly "Chosen Task"); the actual
 * task is picked in Step 2.
 */
export function BoardSetupForm({
  name,
  onNameChange,
  size,
  onSizeChange,
  timeframe,
  onTimeframeChange,
  timeframeLocked = false,
  customStartDate,
  onCustomStartDateChange,
  customEndDate,
  onCustomEndDateChange,
  centerType,
  onCenterTypeChange,
  centerCustomName,
  onCenterCustomNameChange,
  isRandomized,
  onIsRandomizedChange,
  isRecurring,
  onIsRecurringChange,
  weekStartDay,
}: BoardSetupFormProps): React.ReactElement {
  const isOddBoard = size % 2 !== 0;
  const visibleTimeframeOptions = isRecurring
    ? RECURRING_TIMEFRAME_OPTIONS
    : TIMEFRAME_OPTIONS;
  const visibleCenterTypeOptions = isRecurring
    ? RECURRING_CENTER_TYPE_OPTIONS
    : CENTER_TYPE_OPTIONS;

  const computedBoundaries =
    timeframe !== Timeframe.CUSTOM
      ? getTimeframeBoundaries(timeframe, new Date(), weekStartDay)
      : null;

  const timeframeLabel = computedBoundaries
    ? formatTimeframeLabel(timeframe, computedBoundaries.startDate)
    : null;

  return (
    <div className={styles.form}>
      {/* Board name */}
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor="bw-board-name">
          Board name<span className={styles.required}>*</span>
        </label>
        <input
          id="bw-board-name"
          type="text"
          className={styles.input}
          value={name}
          onChange={(e) => onNameChange(e.target.value)}
          placeholder='e.g., "Spring Goals"'
          maxLength={200}
        />
      </div>

      {/* Board size */}
      <div className={styles.fieldGroup}>
        <span className={styles.label}>Board size</span>
        <div className={styles.segmented}>
          {SIZE_OPTIONS.map((opt) => (
            <button
              key={opt.value}
              type="button"
              className={`${styles.segmentedButton} ${
                size === opt.value ? styles.segmentedButtonActive : ""
              }`}
              onClick={() => onSizeChange(opt.value)}
              aria-pressed={size === opt.value}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </div>

      {/* Timeframe */}
      <div className={styles.fieldGroup}>
        <span className={styles.label}>Timeframe</span>
        {timeframeLocked ? (
          <div className={styles.segmented}>
            {/* Render only the locked timeframe — visually identical to a
             *  selected segmented button but disabled, with a small hint
             *  underneath explaining the lock came from the recurring
             *  banner. Mirrors the iOS prefilled-chip variant. */}
            <button
              type="button"
              className={`${styles.segmentedButton} ${styles.segmentedButtonActive}`}
              disabled
              aria-pressed
            >
              {TIMEFRAME_OPTIONS.find((o) => o.value === timeframe)?.label ??
                String(timeframe)}
            </button>
          </div>
        ) : (
          <div className={styles.segmented}>
            {visibleTimeframeOptions.map((opt) => (
              <button
                key={opt.value}
                type="button"
                className={`${styles.segmentedButton} ${
                  timeframe === opt.value ? styles.segmentedButtonActive : ""
                }`}
                onClick={() => onTimeframeChange(opt.value)}
                aria-pressed={timeframe === opt.value}
              >
                {opt.label}
              </button>
            ))}
          </div>
        )}
        {timeframeLocked && (
          <p className={styles.hint}>
            Timeframe set from the recurring boards banner. Cancel and use
            "Start a new board" to pick a different one.
          </p>
        )}
      </div>

      {/* Recurring toggle (Phase 6.2). Rendered between Timeframe and
          Center cell so the user sees recurrence affect the timeframe
          options visibly. The pool is always loose-fit — extras become
          the random subset for each spawn. */}
      <div className={styles.fieldGroup}>
        <label className={styles.checkboxRow}>
          <input
            type="checkbox"
            checked={isRecurring}
            onChange={(e) => onIsRecurringChange(e.target.checked)}
          />
          <span>
            <strong>Make recurring</strong>
            <span className={styles.checkboxSubtitle}>
              {" "}
              — automatically create a fresh board each window from a task pool.
            </span>
          </span>
        </label>
      </div>

      {/* Date display — auto for non-Custom, pickers for Custom.
          Recurring boards show a cadence label ("Every week") with
          the first-spawn window as the caption, so the wizard makes
          the recurrence visible instead of looking identical to a
          one-off board for the same window. */}
      {timeframe !== Timeframe.CUSTOM && computedBoundaries && (
        <div className={styles.dateDisplay}>
          <span className={styles.dateDisplayLabel}>
            {isRecurring ? formatRecurringCadence(timeframe) : timeframeLabel}
          </span>
          <span className={styles.dateDisplayRange}>
            {isRecurring
              ? `Starting: ${timeframeLabel}`
              : `${computedBoundaries.startDate.split("T")[0]} to ${computedBoundaries.endDate.split("T")[0]}`}
          </span>
        </div>
      )}

      {timeframe === Timeframe.CUSTOM && (
        <div className={styles.dateRow}>
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="bw-start-date">
              Start date
            </label>
            <input
              id="bw-start-date"
              type="date"
              className={styles.input}
              value={customStartDate}
              onChange={(e) => onCustomStartDateChange(e.target.value)}
            />
          </div>
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="bw-end-date">
              End date
            </label>
            <input
              id="bw-end-date"
              type="date"
              className={styles.input}
              value={customEndDate}
              onChange={(e) => onCustomEndDateChange(e.target.value)}
            />
          </div>
        </div>
      )}

      {/* Center square — only for odd boards */}
      {isOddBoard && (
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="bw-center-type">
            Center square
          </label>
          <select
            id="bw-center-type"
            className={styles.input}
            value={centerType}
            onChange={(e) =>
              onCenterTypeChange(e.target.value as CenterSquareType)
            }
          >
            {visibleCenterTypeOptions.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
          {centerType === CenterSquareType.CHOSEN && (
            <p className={styles.hint}>
              You'll mark which selected task is the center in the next step.
            </p>
          )}
        </div>
      )}

      {/* Custom center name */}
      {isOddBoard && centerType === CenterSquareType.CUSTOM_FREE && (
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="bw-center-custom-name">
            Custom center name
          </label>
          <input
            id="bw-center-custom-name"
            type="text"
            className={styles.input}
            value={centerCustomName}
            onChange={(e) => onCenterCustomNameChange(e.target.value)}
            placeholder='e.g., "Wild Card"'
            maxLength={100}
          />
        </div>
      )}

      {/* Randomize */}
      <label className={styles.checkboxRow}>
        <input
          type="checkbox"
          checked={isRandomized}
          onChange={(e) => onIsRandomizedChange(e.target.checked)}
        />
        <span>Randomize task positions on the board</span>
      </label>
    </div>
  );
}
