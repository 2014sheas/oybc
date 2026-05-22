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

  customStartDate: string;
  onCustomStartDateChange: (d: string) => void;
  customEndDate: string;
  onCustomEndDateChange: (d: string) => void;

  centerType: CenterSquareType;
  onCenterTypeChange: (t: CenterSquareType) => void;
  centerCustomName: string;
  onCenterCustomNameChange: (n: string) => void;

  /** Phase 6.2 — read-only flag (set at wizard entry, no in-form
   *  toggle since #71). When true the wizard saves a recurring template;
   *  the form hides `Timeframe.CUSTOM` and `CenterSquareType.CHOSEN`
   *  (the recurring schema rejects both) and shows the cadence label. */
  isRecurring: boolean;

  /** Issue #70 — when true this is a *core* board for a specific
   *  timeframe window (launched from the Boards-tab banner / core-board
   *  browser). The form collapses to only Board size + Center space:
   *  the title is auto-set from the window label (shown read-only), the
   *  timeframe is fixed to the window, and there's no recurring option. */
  isCore: boolean;

  weekStartDay: WeekStartDay;
}

/**
 * BoardSetupForm — Pure presentational form for the wizard's Setup step.
 *
 * Renders configuration controls (name, size, timeframe, custom dates,
 * center type, custom name input) without owning any state. The wizard
 * controller drives every field via the `on*Change` callbacks.
 *
 * Three layouts, gated by the read-only `isCore` / `isRecurring` flags:
 *   - **Core** (`isCore`): only board size + center, with a read-only
 *     window caption. Title/timeframe are fixed to the window (#70).
 *   - **Recurring** (`isRecurring`): name + size + timeframe (no Custom)
 *     + center, with a cadence label. No "Make recurring" toggle — the
 *     mode is chosen at the Create hub (#71).
 *   - **One-off** (default): name + size + timeframe (incl. Custom) +
 *     center.
 *
 * Center-type options for odd boards include the renamed
 * "Pick one of my board tasks" (formerly "Chosen Task"); the actual
 * task is picked in Step 2. Placement is always randomized (#69), so
 * there's no randomize toggle.
 */
export function BoardSetupForm({
  name,
  onNameChange,
  size,
  onSizeChange,
  timeframe,
  onTimeframeChange,
  customStartDate,
  onCustomStartDateChange,
  customEndDate,
  onCustomEndDateChange,
  centerType,
  onCenterTypeChange,
  centerCustomName,
  onCenterCustomNameChange,
  isRecurring,
  isCore,
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

  // Reusable Center-square block — shared by all three layouts.
  const centerBlock = (
    <>
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
              You'll pick the center in the next step.
            </p>
          )}
        </div>
      )}
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
    </>
  );

  // Reusable Board-size block — shared by all three layouts.
  const sizeBlock = (
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
  );

  // Issue #70 — core boards only configure size + center. The title is
  // auto-set from the window label (rendered read-only) and the
  // timeframe is fixed to the window, so neither is a control here.
  if (isCore) {
    return (
      <div className={styles.form}>
        <div className={styles.dateDisplay}>
          <span className={styles.dateDisplayLabel}>Core board for</span>
          <span className={styles.dateDisplayRange}>{name || "this window"}</span>
        </div>
        {sizeBlock}
        {centerBlock}
      </div>
    );
  }

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
      {sizeBlock}

      {/* Timeframe */}
      <div className={styles.fieldGroup}>
        <span className={styles.label}>Timeframe</span>
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

      {/* Center square + custom name (shared with the core layout) */}
      {centerBlock}
    </div>
  );
}
