import {
  CenterSquareType,
  Timeframe,
  fillableCellCount,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  type WeekStartDay,
} from "@oybc/shared";
import { RisoIcon } from "../riso";
import { BoardSizeCards } from "./BoardSizeCards";
import styles from "./BoardSetupForm.module.css";

const TIMEFRAME_OPTIONS: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: "Daily" },
  { value: Timeframe.WEEKLY, label: "Weekly" },
  { value: Timeframe.MONTHLY, label: "Monthly" },
  { value: Timeframe.YEARLY, label: "Yearly" },
  { value: Timeframe.CUSTOM, label: "Custom" },
];

/**
 * Board Creation Split (web PR C) — the recurring Setup's "Repeats every"
 * segmented: a bare cadence (Day/Week/Month/Year), no Custom (the
 * recurring schema rejects it — no computed window/cadence). Bound
 * directly to `timeframe`/`onTimeframeChange` — a recurring board's
 * cadence IS its timeframe, so there's no separate "Repeats" field
 * layered on top (that mid-wizard toggle retired with the split).
 */
const RECURRING_CADENCE_OPTIONS: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: "Day" },
  { value: Timeframe.WEEKLY, label: "Week" },
  { value: Timeframe.MONTHLY, label: "Month" },
  { value: Timeframe.YEARLY, label: "Year" },
];

const CENTER_TYPE_OPTIONS: { value: CenterSquareType; label: string }[] = [
  { value: CenterSquareType.FREE, label: "Free Space" },
  { value: CenterSquareType.CHOSEN, label: "Pick one of my board tasks" },
  { value: CenterSquareType.NONE, label: "None" },
];

/** Subset of `CENTER_TYPE_OPTIONS` shown when `isRecurring=true`. The
 *  recurring template MVP excludes `CenterSquareType.CHOSEN` — adding
 *  a per-template `centerTaskId` is a future extension. */
const RECURRING_CENTER_TYPE_OPTIONS = CENTER_TYPE_OPTIONS.filter(
  (o) => o.value !== CenterSquareType.CHOSEN,
);

/**
 * Lowercase singular cadence noun for the recurring note's "every {noun}"
 * slot. `CUSTOM`/`INDEFINITE` are unreachable while `isRecurring` (the
 * segmented above never offers them) — `'week'` is a defensive fallback,
 * never actually shown. Mirrors iOS `RisoBoardSetupForm.recurringCadenceNoun`.
 */
function recurringCadenceNoun(t: Timeframe): string {
  switch (t) {
    case Timeframe.DAILY:
      return "day";
    case Timeframe.WEEKLY:
      return "week";
    case Timeframe.MONTHLY:
      return "month";
    case Timeframe.YEARLY:
      return "year";
    case Timeframe.CUSTOM:
    case Timeframe.INDEFINITE:
      return "week";
  }
}

export interface BoardSetupFormProps {
  /**
   * Rendering mode:
   *   - `'create'` (default): full wizard setup step. Board size is
   *     editable. "Continue to tasks" affordances may be shown by the wizard.
   *   - `'edit-active'`: editing an already-active board. Board size is
   *     rendered as a read-only chip (passed through for display only;
   *     `onSizeChange` is a no-op). Wizard-only affordances are hidden.
   *
   * Existing callers that do not pass `mode` default to `'create'`, so
   * the wizard, recurring-template setup, and composite wizard are all
   * unaffected.
   */
  mode?: 'create' | 'edit-active';

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

  /**
   * Board Creation Split (web PR C) — whether this wizard session is the
   * recurring (BLUE) or one-off (RED) flow. Fixed at wizard entry (see
   * `useBoardWizard`'s `isRecurring`) — there is no mid-form "Repeats"
   * control anymore that flips it. Drives which schedule field renders
   * (Timeframe segmented vs. "Repeats every" segmented), which center
   * options are offered (CHOSEN is recurring-excluded), and the
   * board-size requirement caption. Ignored (no schedule field at all)
   * in the core layout, and in `edit-active` mode (always `false` there
   * — recurring boards aren't editable via the active-board edit sheet).
   */
  isRecurring: boolean;

  /** Issue #70 — when true this is a *core* board for a specific
   *  timeframe window (launched from the Boards-tab banner / core-board
   *  browser). The form collapses to only Board size + Center space:
   *  the title is auto-set from the window label (shown read-only), the
   *  timeframe is fixed to the window, and there's no recurring option. */
  isCore: boolean;

  weekStartDay: WeekStartDay;

  /**
   * M2 — `edit-active` mode only. When true, the CHOSEN center-square
   * option is disabled with an inline explanation (no candidate tasks on
   * the board yet). Ignored in `create` mode.
   */
  chosenCenterDisabled?: boolean;
}

/**
 * BoardSetupForm — Pure presentational form for the wizard's Setup step.
 *
 * Renders configuration controls (name, size, timeframe, custom dates,
 * center type) without owning any state. The wizard
 * controller drives every field via the `on*Change` callbacks.
 *
 * Three layouts, gated by the read-only `isCore` / `isRecurring` flags:
 *   - **Core** (`isCore`): only board size + center, with a read-only
 *     window caption. Title/timeframe are fixed to the window (#70).
 *   - **Recurring** (`isRecurring`): name + size + "Repeats every"
 *     cadence (no Custom) + center (Free/None only), with a dashed
 *     cadence note. Mode is fixed at wizard entry — chosen at the
 *     Create hub via the RED/BLUE CTAs (Board Creation Split, web PR C),
 *     never toggled mid-form.
 *   - **One-off** (default): name + size + Timeframe (incl. Custom) +
 *     center (Free/Choose/None).
 *
 * Center-type options for odd boards include the renamed
 * "Pick one of my board tasks" (formerly "Chosen Task"); the actual
 * task is picked in Step 2. Placement is always randomized (#69), so
 * there's no randomize toggle.
 */
export function BoardSetupForm({
  mode = 'create',
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
  isRecurring,
  isCore,
  weekStartDay,
  chosenCenterDisabled = false,
}: BoardSetupFormProps): React.ReactElement {
  const isEditActive = mode === 'edit-active';
  const isOddBoard = size % 2 !== 0;
  const visibleCenterTypeOptions = isRecurring
    ? RECURRING_CENTER_TYPE_OPTIONS
    : CENTER_TYPE_OPTIONS;

  // Custom (user-picked dates) and Indefinite (no end date) have no computed
  // window — getTimeframeBoundaries throws for both. Recurring boards never
  // carry either (the cadence segmented below excludes them), so this
  // always resolves for a recurring session.
  const computedBoundaries =
    timeframe !== Timeframe.CUSTOM && timeframe !== Timeframe.INDEFINITE
      ? getTimeframeBoundaries(timeframe, new Date(), weekStartDay)
      : null;

  const timeframeLabel = computedBoundaries
    ? formatTimeframeLabel(timeframe, computedBoundaries.startDate)
    : null;

  // Reusable Center-square block — shared by all three layouts.
  // In `edit-active` mode with `chosenCenterDisabled`, the CHOSEN option
  // is disabled with an explanatory note (no candidate task in boardTasks).
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
            {visibleCenterTypeOptions.map((opt) => {
              const isChosenDisabled =
                isEditActive &&
                chosenCenterDisabled &&
                opt.value === CenterSquareType.CHOSEN;
              return (
                <option
                  key={opt.value}
                  value={opt.value}
                  disabled={isChosenDisabled}
                >
                  {opt.label}
                  {isChosenDisabled ? ' (no placed tasks)' : ''}
                </option>
              );
            })}
          </select>
          {centerType === CenterSquareType.CHOSEN && !isEditActive && (
            <p className={styles.hint}>
              You'll pick the center in the next step.
            </p>
          )}
          {centerType === CenterSquareType.CHOSEN && isEditActive && (
            <p className={styles.hint}>
              The existing center task is kept. Switch away to change the center type.
            </p>
          )}
        </div>
      )}
    </>
  );

  // Reusable Board-size block — shared by all three layouts. Board
  // Creation Split (web PR C) — the dot-matrix `BoardSizeCards` replaces
  // the old flat segmented buttons (mirrors iOS `RisoBoardSizeCards`).
  // In `edit-active` mode, size is rendered as a read-only chip (immutable
  // on active boards — changing it would force re-placement of every cell).
  // The EditBoardSheet renders its own chip; the form renders nothing here
  // so there's no double-chip in the sheet layout.
  const sizeBlock = !isEditActive ? (
    <div className={styles.fieldGroup}>
      <span className={styles.label}>Board size</span>
      <BoardSizeCards selectedSize={size} onSelect={onSizeChange} />
      {/* Upfront requirement line — surfaces the task-count cost live with
          the size + center selection so the user isn't blindsided by a
          disabled Next later. Count is the shared `fillableCellCount`
          (odd + FREE center reserves one cell). Copy diverges per mode
          (README §Copy strings): one-off states the exact requirement;
          recurring drops the "A n×n board" framing since overfill is the
          intended variety mechanism there. */}
      <p className={styles.requirementNote}>
        {isRecurring
          ? `Needs at least ${fillableCellCount(size, centerType)} tasks — extras rotate in.`
          : `A ${size}×${size} board needs ${fillableCellCount(size, centerType)} tasks.`}
      </p>
    </div>
  ) : null;

  // Issue #70 — core boards only configure size + center. The title is
  // auto-set from the window label (rendered read-only) and the
  // timeframe is fixed to the window, so neither is a control here.
  // Core boards are always one-off (never recurring).
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

      {/* Schedule — one-off's Timeframe segmented (incl. Custom), OR
          recurring's "Repeats every" cadence segmented (no Custom). Board
          Creation Split (web PR C) — mutually exclusive per the wizard's
          fixed mode; there's no in-form toggle between them anymore.
          Hidden entirely in `edit-active` mode (recurrence and timeframe
          aren't editable from the active-board edit sheet — see
          `BoardEditPanel`, which always passes `isRecurring={false}`). */}
      {!isEditActive && !isRecurring && (
        <div className={styles.fieldGroup}>
          <span className={styles.label}>Timeframe</span>
          <div className={styles.segmented} role="group" aria-label="Timeframe">
            {TIMEFRAME_OPTIONS.map((opt) => {
              // The "Custom" segment also represents an ongoing (INDEFINITE)
              // board — the End-date "None" option below is where that's chosen.
              const active =
                timeframe === opt.value ||
                (opt.value === Timeframe.CUSTOM &&
                  timeframe === Timeframe.INDEFINITE);
              return (
                <button
                  key={opt.value}
                  type="button"
                  className={`${styles.segmentedButton} ${
                    active ? styles.segmentedButtonActive : ""
                  }`}
                  onClick={() => {
                    // "Custom" defaults to an ongoing board (End date = None); a
                    // date is opt-in. Arriving from a calendar timeframe lands on
                    // None; re-tapping Custom keeps the current End-date choice.
                    if (opt.value === Timeframe.CUSTOM) {
                      if (
                        timeframe !== Timeframe.CUSTOM &&
                        timeframe !== Timeframe.INDEFINITE
                      ) {
                        onTimeframeChange(Timeframe.INDEFINITE);
                      }
                      return;
                    }
                    onTimeframeChange(opt.value);
                  }}
                  aria-pressed={active}
                >
                  {opt.label}
                </button>
              );
            })}
          </div>
        </div>
      )}

      {!isEditActive && isRecurring && (
        <div className={styles.fieldGroup}>
          <span className={styles.label}>Repeats every</span>
          <div className={styles.segmented} role="group" aria-label="Repeats every">
            {RECURRING_CADENCE_OPTIONS.map((opt) => {
              const active = timeframe === opt.value;
              return (
                <button
                  key={opt.value}
                  type="button"
                  className={`${styles.segmentedButton} ${
                    active ? styles.segmentedButtonActive : ""
                  }`}
                  onClick={() => onTimeframeChange(opt.value)}
                  aria-pressed={active}
                >
                  {opt.label}
                </button>
              );
            })}
          </div>
          {timeframeLabel && (
            <p className={styles.hint}>
              <RisoIcon name="repeat" size={14} />
              {`A fresh board every ${recurringCadenceNoun(timeframe)} · starts ${timeframeLabel}`}
            </p>
          )}
        </div>
      )}

      {/* Date display — auto for non-Custom, pickers for Custom. One-off
          only: a recurring board's date is fully covered by the "Repeats
          every" note above. */}
      {!isRecurring && timeframe !== Timeframe.CUSTOM && computedBoundaries && (
        <div className={styles.dateDisplay}>
          <span className={styles.dateDisplayLabel}>{timeframeLabel}</span>
          <span className={styles.dateDisplayRange}>
            {`${computedBoundaries.startDate.split("T")[0]} to ${computedBoundaries.endDate.split("T")[0]}`}
          </span>
        </div>
      )}

      {!isRecurring &&
        (timeframe === Timeframe.CUSTOM ||
          timeframe === Timeframe.INDEFINITE) && (
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
            <label className={styles.label} htmlFor="bw-end-date-mode">
              End date
            </label>
            {/* "None" is a first-class option here (not a toggle): selecting it
                makes the board ongoing/indefinite. An HTML date input can't show
                a "None" state, so a small select drives the mode and the date
                input appears only when a date is chosen. */}
            <select
              id="bw-end-date-mode"
              className={styles.input}
              value={timeframe === Timeframe.INDEFINITE ? "none" : "date"}
              onChange={(e) =>
                onTimeframeChange(
                  e.target.value === "none"
                    ? Timeframe.INDEFINITE
                    : Timeframe.CUSTOM,
                )
              }
            >
              <option value="date">On a date</option>
              <option value="none">None — no end date</option>
            </select>
            {timeframe === Timeframe.CUSTOM && (
              <input
                id="bw-end-date"
                type="date"
                className={styles.input}
                value={customEndDate}
                onChange={(e) => onCustomEndDateChange(e.target.value)}
              />
            )}
          </div>
        </div>
      )}

      {/* Center square (shared with the core layout) */}
      {centerBlock}
    </div>
  );
}
