import {
  memberRuleFor,
  type BoardSource,
  type BoardWindow,
  type CompoundChild,
  type PlanMode,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import type { WizardSourceSupply } from '../../pages/createHub/wizardSources';
import { RisoSegmented } from '../riso';
import { MemberRuleRow, type MemberState } from './MemberRuleRow';
import { RangeSlider } from './RangeSlider';
import styles from './SourceRow.module.css';

export interface SourceRowProps {
  source: BoardSource;
  supply: WizardSourceSupply;
  /** Post-exclude, post-filter count — the slider's N and "of N". */
  availableCount: number;
  isExpanded: boolean;
  /** Member titles + type badges (the step's `effectiveTaskMap` so staged
   *  inline edits show through). */
  taskById: Record<string, Task>;
  onToggleExpanded: () => void;
  onRemove: () => void;
  onSetFilter: (filter: 'all' | 'todo') => void;
  onSetRange: (min: number, max: number | null) => void;
  onToggleExclude: (taskId: string) => void;
  /** Counter-family exclusivity — member id → the OTHER family member's
   *  title, when both are visible in the pool ("one per board" hint). */
  counterClashByTaskId?: Map<string, string>;
  /** Children per compound — feeds the Split-up part lines. */
  compoundChildrenByCompound?: Record<string, CompoundChild[]>;
  // ── §Member rules (B3) — per-member rule editing. ──────────────────────
  /** Whether the board being assembled is one-off or repeating. */
  mode: PlanMode;
  /** The window of the board being assembled (pro-rating target window). */
  wizardWindow: BoardWindow;
  onSetMemberTarget: (taskId: string, target: number | undefined) => void;
  onSetMemberVary: (taskId: string, level: VaryLevel) => void;
  onSetMemberSplit: (taskId: string, split: boolean) => void;
  onSetPartExcluded: (taskId: string, childId: string, excluded: boolean) => void;
  onSetPartTarget: (taskId: string, childId: string, target: number | undefined) => void;
  onSetPartVary: (taskId: string, childId: string, level: VaryLevel) => void;
}

/**
 * SourceRow — one pulled source's row in the wizard's "On your board"
 * list (Board Sources P4 — docs/BOARD_SOURCES.md §Surfaces item 1;
 * handoff frames 2a/4a). Web port of iOS `RisoSourceRowView`.
 *
 * Collapsed: letter square (pool = ink "P", board = gold + ink-static "B"
 * per the dark contract), name, live subtitle, chevron, ✕. Tapping the
 * header toggles the expanded panel: (boards only) the All squares / Not
 * done yet segmented, the range block (kicker, range label, "Use all",
 * the two-handle `RangeSlider`, the non-default note line), then the
 * member rows — each a `MemberRuleRow`, which owns the ✕/UNDO/✓ control
 * AND the §Member rules controls (target stepper, dice, One square /
 * Split up + part lines).
 *
 * Header is a plain (non-interactive) container holding two SIBLING
 * buttons: the disclosure (letter, name, subtitle, chevron) and the ✕,
 * overlaid on the disclosure's trailing gutter — the `MemberRuleRow`
 * layout. Never a control nested inside a `role="button"`: the wrapper's
 * Enter/Space handler would cancel the inner button's activation and
 * toggle the panel instead (2026-09 audit). The iOS row has the same rule
 * for gesture arbitration.
 */
export function SourceRow({
  source,
  supply,
  availableCount,
  isExpanded,
  taskById,
  onToggleExpanded,
  onRemove,
  onSetFilter,
  onSetRange,
  onToggleExclude,
  counterClashByTaskId,
  compoundChildrenByCompound,
  mode,
  wizardWindow,
  onSetMemberTarget,
  onSetMemberVary,
  onSetMemberSplit,
  onSetPartExcluded,
  onSetPartTarget,
  onSetPartVary,
}: SourceRowProps): React.ReactElement {
  const isDefaultRange = source.min === 0 && source.max === null;
  const effectiveMax = source.max ?? availableCount;
  const rangeText =
    source.min === effectiveMax ? `${source.min}` : `${source.min}–${effectiveMax}`;

  const subtitle = buildSubtitle(source, supply, isDefaultRange, rangeText);

  const memberState = (taskId: string): MemberState => {
    if (source.kind === 'board' && source.filter === 'todo' && supply.doneTaskIds.has(taskId)) {
      return 'filteredDone';
    }
    if (source.excludedTaskIds.includes(taskId)) return 'excluded';
    return 'included';
  };

  return (
    <li className={styles.card}>
      <div className={styles.headerRow}>
        <button
          type="button"
          className={styles.headerToggle}
          aria-expanded={isExpanded}
          aria-label={`${supply.displayName}, ${subtitle}`}
          onClick={onToggleExpanded}
        >
          <span
            className={source.kind === 'pool' ? styles.letterPool : styles.letterBoard}
            aria-hidden="true"
          >
            {source.kind === 'pool' ? 'P' : 'B'}
          </span>
          <span className={styles.headerText}>
            <span className={styles.headerName}>{supply.displayName}</span>
            <span className={styles.headerSubtitle}>{subtitle}</span>
          </span>
          <span
            className={`${styles.chevron} ${isExpanded ? styles.chevronOpen : ''}`}
            aria-hidden="true"
          >
            ›
          </span>
        </button>
        {/* A SIBLING of the disclosure, never nested inside it. */}
        <button
          type="button"
          className={styles.removeButton}
          onClick={onRemove}
          aria-label={`Remove ${supply.displayName}`}
        >
          ✕
        </button>
      </div>

      {isExpanded && (
        <div className={styles.panel}>
          {source.kind === 'board' && (
            <div className={styles.filterWrap}>
              <RisoSegmented
                options={[
                  { value: 'all', label: 'All squares' },
                  { value: 'todo', label: 'Not done yet' },
                ]}
                value={source.filter}
                onChange={onSetFilter}
                variant="pill"
                aria-label="Which squares to pull"
              />
            </div>
          )}

          <div className={styles.rangeBlock}>
            <div className={styles.rangeTitleRow}>
              <span className={styles.rangeKicker}>On the board</span>
              <span className={styles.rangeLabel}>{rangeText}</span>
              <span className={styles.rangeOf}>of {availableCount}</span>
              <button
                type="button"
                className={styles.useAllButton}
                disabled={isDefaultRange}
                onClick={() => onSetRange(0, null)}
              >
                Use all
              </button>
            </div>
            <RangeSlider
              available={availableCount}
              minValue={Math.min(source.min, availableCount)}
              maxValue={source.max}
              onChange={onSetRange}
            />
            {!isDefaultRange && (
              <p className={styles.rangeNote}>
                {source.min === effectiveMax
                  ? `${source.min} of these will be on the board.`
                  : `Between ${source.min} and ${effectiveMax} of these will be on the board.`}
              </p>
            )}
          </div>

          <ul className={styles.memberList}>
            {supply.rawSupplyTaskIds.map((taskId) => (
              <MemberRuleRow
                key={taskId}
                task={taskById[taskId]}
                taskById={taskById}
                state={memberState(taskId)}
                clashTitle={counterClashByTaskId?.get(taskId)}
                rule={memberRuleFor(source, taskId)}
                parts={compoundChildrenByCompound?.[taskId] ?? []}
                fromBoard={source.kind === 'board'}
                sourceWindow={supply.sourceWindow}
                wizardWindow={wizardWindow}
                mode={mode}
                onToggleExclude={() => onToggleExclude(taskId)}
                onSetTarget={(target) => onSetMemberTarget(taskId, target)}
                onSetVary={(level) => onSetMemberVary(taskId, level)}
                onSetSplit={(split) => onSetMemberSplit(taskId, split)}
                onSetPartExcluded={(childId, excluded) =>
                  onSetPartExcluded(taskId, childId, excluded)
                }
                onSetPartTarget={(childId, target) => onSetPartTarget(taskId, childId, target)}
                onSetPartVary={(childId, level) => onSetPartVary(taskId, childId, level)}
              />
            ))}
          </ul>
        </div>
      )}
    </li>
  );
}

/** docs/BOARD_SOURCES.md §Surfaces "Subtitles": pool — "8 tasks" (+ " · 1
 *  excluded", + " · 3–5 on the board" only when range ≠ default); board —
 *  "6 squares · 4 done" / "2 not done". Mirrors iOS `subtitle`. */
function buildSubtitle(
  source: BoardSource,
  supply: WizardSourceSupply,
  isDefaultRange: boolean,
  rangeText: string,
): string {
  const parts: string[] = [];
  if (source.kind === 'pool') {
    const total = supply.rawSupplyTaskIds.length;
    parts.push(`${total} task${total === 1 ? '' : 's'}`);
    const excludedCount = source.excludedTaskIds.filter((id) =>
      supply.rawSupplyTaskIds.includes(id),
    ).length;
    if (excludedCount > 0) parts.push(`${excludedCount} excluded`);
  } else if (source.filter === 'todo') {
    const notDone = supply.rawSupplyTaskIds.filter((id) => !supply.doneTaskIds.has(id)).length;
    parts.push(`${notDone} not done`);
  } else {
    const total = supply.rawSupplyTaskIds.length;
    parts.push(`${total} square${total === 1 ? '' : 's'} · ${supply.doneTaskIds.size} done`);
  }
  if (!isDefaultRange) parts.push(`${rangeText} on the board`);
  return parts.join(' · ');
}
