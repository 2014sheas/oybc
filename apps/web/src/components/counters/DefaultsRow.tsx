import { COUNTER_GOAL_TIMEFRAMES, formatCountForInput, parseCountInput, type CounterGoalTimeframe, type CountKind } from '@oybc/shared';
import { GoalEntry } from './GoalEntry';
import { DEFAULTS_ROW_LABELS, defaultsCellIsSet, type DefaultsRowEntered } from './defaultsRowModel';
import styles from './DefaultsRow.module.css';

export interface DefaultsRowProps {
  kind: CountKind;
  /** Unit suffix inside each Discrete / Continuous cell. */
  unit: string;
  /** The typed text per cell. */
  entered: DefaultsRowEntered;
  onChange: (timeframe: CounterGoalTimeframe, text: string) => void;
  /** The D4-derived value per UNSET cell (`derivedTimeframeGoals`); null = nothing to show. */
  derived: Record<CounterGoalTimeframe, number | null>;
  /** Prefix for the four cells' input ids. */
  idPrefix: string;
}

/**
 * DefaultsRow — Daily · Weekly · Monthly · Yearly default goals
 * (docs/SHARED_COUNTER_SETTINGS.md §1c; design handoff `DefaultsRow.dc.html`).
 * A 2×2 grid of kind-aware `GoalEntry` cells. Set = solid (ink, 2px keyline);
 * unset = the value D4 derives from the nearest set cell, DIMMED (muted,
 * hairline) as real text the user types over; nothing set → every cell
 * empty. Typing makes a cell solid; clearing returns it to derived. The pure
 * helpers live in `defaultsRowModel.ts`. iOS twin: `DefaultsRowView`.
 *
 * @returns The labelled grid.
 */
export function DefaultsRow({ kind, unit, entered, onChange, derived, idPrefix }: DefaultsRowProps): React.ReactElement {
  return (
    <div className={styles.wrap}>
      <span className={styles.label}>Defaults</span>
      <div className={styles.grid}>
        {COUNTER_GOAL_TIMEFRAMES.map((t) => {
          const isSet = defaultsCellIsSet(entered, t);
          const d = derived[t];
          const dim = !isSet && d !== null;
          const value = isSet ? (entered[t] ?? '') : d !== null ? formatCountForInput(d, kind) : '';
          const invalid = isSet && parseCountInput(entered[t]!, kind) === null;
          return (
            <div className={styles.cell} key={t} data-dim={dim || undefined}>
              <span className={styles.cellName} id={`${idPrefix}-${t}-label`}>
                {DEFAULTS_ROW_LABELS[t]}
              </span>
              <GoalEntry
                kind={kind}
                id={`${idPrefix}-${t}`}
                aria-label={`${DEFAULTS_ROW_LABELS[t]} default`}
                value={value}
                onChange={(next) => onChange(t, next)}
                placeholder=""
                suffix={kind === 'duration' ? undefined : unit}
                dim={dim}
                invalid={invalid}
                dense
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}
