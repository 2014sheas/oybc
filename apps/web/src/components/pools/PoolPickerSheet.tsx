import { useMemo, useState } from 'react';
import { formatPoolShortSummary } from '@oybc/shared';
import type { Pool, RecurringBoardTemplate, Task } from '@oybc/shared';
import { RisoButton, RisoChip } from '../riso';
import { PoolEditSheet } from './PoolEditSheet';
import { computePoolHealthByPoolId } from './poolHealthBatch';
import { shouldSelectAfterPoolCreated } from './poolPickerLogic';
import styles from './PoolPickerSheet.module.css';

export interface PoolPickerSheetProps {
  /** Authenticated user id — owner of a pool minted via "+ Build a new pool…". */
  userId: string;
  /** The user's non-deleted pools. */
  pools: Pool[];
  /** Active recurring-board templates (spawn records) — batched health
   *  input, same as `PoolsBrowse`'s usage of `computePoolHealthByPoolId`. */
  templates: RecurringBoardTemplate[];
  /** id → Task lookup for health + the create-sheet's chip resolution. */
  tasksById: Record<string, Task>;
  /** The draft-filtered subset of tasks — passed straight through to the
   *  nested `PoolEditSheet`'s "reuse a task from your library" picker. */
  browsableTasks: Task[];
  /** Currently-selected pool ids in the launching context (the defaults
   *  sheet's `corePoolIds` or the roster edit sheet's `poolIds`). */
  selectedPoolIds: string[];
  /** Toggles one pool on/off. Applied immediately (live toggle, same UX
   *  as the wizard's "PULL IN A POOL" chips) — this sheet has no separate
   *  staged-then-confirm step. */
  onTogglePool: (poolId: string) => void;
  /** Fired after "+ Build a new pool…" successfully creates a pool. The
   *  caller is responsible for selecting it (typically by calling
   *  `onTogglePool(pool.id)` if it isn't already selected) — this sheet
   *  never assumes a fresh pool is auto-selected on the caller's behalf,
   *  since a caller's selection state may need additional bookkeeping
   *  (e.g. the roster's `poolIds` array). */
  onPoolCreated: (pool: Pool) => void;
  /** Backdrop click / Escape / Done. */
  onClose: () => void;
}

/**
 * PoolPickerSheet — the shared "pick which pools feed this mix" sheet
 * (Task Pools + Recurring Boards Rework, P7, docs/POOLS_RECURRING.md
 * §Surfaces item 10). Used by both the Board-settings defaults sheet
 * (`corePoolIds`) and the repeating-boards roster edit sheet (`poolIds`) —
 * a SELECTOR over existing pools, distinct from `PoolEditSheet` (a single
 * pool's own editor, which this sheet opens in create mode for
 * "+ Build a new pool…").
 *
 * Health per row reuses `computePoolHealthByPoolId` verbatim (never
 * reimplemented) — the same combined "Short on N boards" line the Tasks-tab
 * pool cards show.
 */
export function PoolPickerSheet({
  userId,
  pools,
  templates,
  tasksById,
  browsableTasks,
  selectedPoolIds,
  onTogglePool,
  onPoolCreated,
  onClose,
}: PoolPickerSheetProps): React.ReactElement {
  const [showCreateSheet, setShowCreateSheet] = useState(false);

  const healthByPoolId = useMemo(
    () => computePoolHealthByPoolId(pools, templates, tasksById),
    [pools, templates, tasksById],
  );
  const allTasks = useMemo(() => Object.values(tasksById), [tasksById]);

  function handlePoolCreated(pool: Pool): void {
    setShowCreateSheet(false);
    onPoolCreated(pool);
    if (shouldSelectAfterPoolCreated(pool.id, selectedPoolIds)) onTogglePool(pool.id);
  }

  return (
    <>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="pool-picker-sheet-title"
        className={styles.backdrop}
        onClick={onClose}
      >
        <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
          <div className={styles.header}>
            <h3 id="pool-picker-sheet-title" className={styles.title}>
              Choose pools
            </h3>
            <RisoButton kind="neutral" size="small" onClick={onClose}>
              Done
            </RisoButton>
          </div>

          <div className={styles.body}>
            {pools.length === 0 ? (
              <p className={styles.empty}>You don&apos;t have any pools yet.</p>
            ) : (
              <ul className={styles.list} role="group" aria-label="Pools">
                {pools.map((pool) => {
                  const isSelected = selectedPoolIds.includes(pool.id);
                  const health = healthByPoolId[pool.id] ?? { taskCount: 0, consumers: [] };
                  const shortSummary = formatPoolShortSummary(health.consumers);
                  return (
                    <li key={pool.id} className={styles.row}>
                      <RisoChip on={isSelected} onClick={() => onTogglePool(pool.id)}>
                        {pool.name}
                      </RisoChip>
                      <span className={styles.rowMeta}>
                        {health.taskCount} task{health.taskCount === 1 ? '' : 's'}
                        {shortSummary !== '' && (
                          <span className={styles.rowWarning}> · {shortSummary}</span>
                        )}
                      </span>
                    </li>
                  );
                })}
              </ul>
            )}

            <button
              type="button"
              className={styles.newPoolButton}
              onClick={() => setShowCreateSheet(true)}
            >
              + Build a new pool…
            </button>
          </div>
        </div>
      </div>

      {/* Third-tier stacking context, same convention as `PoolEditSheet`'s
          own nested `NewTaskSheet` layer — the create sheet paints above
          this picker's backdrop. */}
      {showCreateSheet && (
        <div className={styles.createLayer}>
          <PoolEditSheet
            userId={userId}
            templates={templates}
            allTasks={allTasks}
            browsableTasks={browsableTasks}
            onClose={() => setShowCreateSheet(false)}
            onSaved={handlePoolCreated}
            onDeleted={() => setShowCreateSheet(false)}
          />
        </div>
      )}
    </>
  );
}
