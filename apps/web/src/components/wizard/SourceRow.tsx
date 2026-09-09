import { TaskType, type BoardSource, type Task } from '@oybc/shared';
import type { WizardSourceSupply } from '../../pages/createHub/wizardSources';
import { RisoSegmented } from '../riso';
import { TypeBadge } from '../TypeBadge';
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
}

type MemberState = 'included' | 'excluded' | 'filteredDone';

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
 * member rows (✕ exclude / UNDO pill / filtered-done green ✓).
 *
 * Header is a plain container + SIBLING remove button — never a button
 * nested in a button (invalid HTML; the iOS row has the same rule for
 * gesture arbitration).
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
      <div
        className={styles.headerRow}
        role="button"
        tabIndex={0}
        aria-expanded={isExpanded}
        aria-label={`${supply.displayName}, ${subtitle}`}
        onClick={onToggleExpanded}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onToggleExpanded();
          }
        }}
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
        <button
          type="button"
          className={styles.removeButton}
          onClick={(e) => {
            e.stopPropagation();
            onRemove();
          }}
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
            {supply.rawSupplyTaskIds.map((taskId) => {
              const state = memberState(taskId);
              const task = taskById[taskId];
              const title = task?.title || '(untitled task)';
              const clashTitle = counterClashByTaskId?.get(taskId);
              return (
                <li
                  key={taskId}
                  className={`${styles.memberRow} ${state !== 'included' ? styles.memberDimmed : ''}`}
                >
                  <TypeBadge type={task?.type ?? TaskType.NORMAL} letterOnly size="small" />
                  <span className={styles.memberText}>
                    <span
                      className={`${styles.memberTitle} ${state === 'excluded' ? styles.memberStruck : ''}`}
                    >
                      {title}
                    </span>
                    {clashTitle !== undefined && (
                      <span className={styles.memberClashHint}>
                        shares a counter with &ldquo;{clashTitle}&rdquo; &middot; one per board
                      </span>
                    )}
                  </span>
                  {state === 'included' && (
                    <button
                      type="button"
                      className={styles.memberExclude}
                      onClick={() => onToggleExclude(taskId)}
                      aria-label={`Exclude ${title} for this board`}
                    >
                      ✕
                    </button>
                  )}
                  {state === 'excluded' && (
                    <button
                      type="button"
                      className={styles.memberUndo}
                      onClick={() => onToggleExclude(taskId)}
                      aria-label={`Undo excluding ${title}`}
                    >
                      UNDO
                    </button>
                  )}
                  {state === 'filteredDone' && (
                    <span className={styles.memberDoneCheck} aria-label={`${title} is done`}>
                      ✓
                    </span>
                  )}
                </li>
              );
            })}
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
