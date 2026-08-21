import { useEffect, useMemo, useState } from 'react';
import { fillableCellCount, type Pool, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { updateRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';
import { WizardQuickAddRow } from '../wizard/WizardQuickAddRow';
import { RisoButton, RisoIcon, RisoTypeBadge } from '../riso';
import { selectLibraryPickerResults } from '../pools/poolEditSheetSelectors';
import { PoolPickerSheet } from '../pools/PoolPickerSheet';
import {
  addManualTaskToRoster,
  classifyRosterChip,
  hydrateRosterMix,
  pullPoolIntoRoster,
  removeResolvedTaskFromRoster,
  resolveRosterTaskIds,
  untogglePoolFromRoster,
  type RosterMix,
} from './rosterEditLogic';
import styles from './RosterEditSheet.module.css';

export interface RosterEditSheetProps {
  /** Authenticated user id — inherited by quick-added tasks. */
  userId: string;
  /** The repeating board (spawn record) being edited. */
  template: RecurringBoardTemplate;
  /** The user's non-deleted pools — for the pool-picker sheet. */
  pools: Pool[];
  /** Every active repeating board (for the pool picker's health note). */
  templates: RecurringBoardTemplate[];
  /** The user's full non-deleted task library — resolves mix ids to chips. */
  allTasks: Task[];
  /** Draft-filtered subset of `allTasks` — the library-reuse picker's
   *  source list (never the raw library — see `PoolEditSheet`'s prop
   *  docstring for the same rule). */
  browsableTasks: Task[];
  /** Backdrop click / Escape / Cancel / Close. */
  onClose: () => void;
  /** Fired after a successful save. */
  onSaved: () => void;
}

/**
 * RosterEditSheet — the Board-settings repeating-boards roster's "Edit
 * tasks" sheet (Task Pools + Recurring Boards Rework, P7,
 * docs/POOLS_RECURRING.md §Surfaces item 9). Edits a single repeating
 * board's `poolIds` / `manualTaskIds` / `removedTaskIds` directly (no
 * wizard round-trip) via `rosterEditLogic.ts`'s pure pull/untoggle/
 * add/remove functions — pool toggles UNION with the existing mix and
 * NEVER wipe the manual layer (locked decision, §Data model "Union rule").
 *
 * Floor-gated Save: the resolved mix must reach `fillableCellCount(size,
 * center)` before Save is enabled (§Behavior invariants "Fillable floor
 * everywhere") — never a hardcoded 8.
 */
export function RosterEditSheet({
  userId,
  template,
  pools,
  templates,
  allTasks,
  browsableTasks,
  onClose,
  onSaved,
}: RosterEditSheetProps): React.ReactElement {
  const [mix, setMix] = useState<RosterMix>(() => hydrateRosterMix(template));
  const [sessionTaskCache, setSessionTaskCache] = useState<Map<string, Task>>(() => new Map());
  const [showPoolPicker, setShowPoolPicker] = useState(false);
  const [showLibraryPicker, setShowLibraryPicker] = useState(false);
  const [librarySearch, setLibrarySearch] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape' && !busy && !showPoolPicker) onClose();
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose, busy, showPoolPicker]);

  const poolsById = useMemo(() => {
    const m: Record<string, Pool> = {};
    for (const p of pools) m[p.id] = p;
    return m;
  }, [pools]);
  const tasksById = useMemo(() => {
    const m: Record<string, Task> = {};
    for (const t of allTasks) m[t.id] = t;
    for (const [id, t] of sessionTaskCache) m[id] = t;
    return m;
  }, [allTasks, sessionTaskCache]);

  const resolvedTaskIds = useMemo(
    () => resolveRosterTaskIds(mix, poolsById, tasksById),
    [mix, poolsById, tasksById],
  );
  const resolvedTasks = useMemo(
    () => resolvedTaskIds.map((id) => tasksById[id]).filter((t): t is Task => t !== undefined),
    [resolvedTaskIds, tasksById],
  );

  const floor = fillableCellCount(template.boardSize, template.centerSquareType);
  const remaining = Math.max(0, floor - resolvedTasks.length);
  const canSave = remaining === 0 && !busy;

  const selectedIdSet = useMemo(() => new Set(resolvedTaskIds), [resolvedTaskIds]);
  const libraryResults = useMemo(
    () => selectLibraryPickerResults(browsableTasks, selectedIdSet, librarySearch),
    [browsableTasks, selectedIdSet, librarySearch],
  );

  function handleTogglePool(poolId: string): void {
    setMix((prev) =>
      prev.poolIds.includes(poolId)
        ? untogglePoolFromRoster(poolId, prev, poolsById)
        : pullPoolIntoRoster(poolId, prev, poolsById),
    );
  }

  function handlePoolCreated(pool: Pool): void {
    // The pool itself lands in `pools` via the caller's live query; no
    // local bookkeeping needed here beyond what `PoolPickerSheet` already
    // does (it calls `onTogglePool` for us when the pool isn't selected).
    void pool;
  }

  function addTask(task: Task): void {
    setSessionTaskCache((cache) => {
      if (cache.get(task.id) === task) return cache;
      const next = new Map(cache);
      next.set(task.id, task);
      return next;
    });
    setMix((prev) => addManualTaskToRoster(task.id, prev));
  }

  function removeChip(taskId: string): void {
    setMix((prev) => removeResolvedTaskFromRoster(taskId, prev, poolsById));
  }

  async function handleSave(): Promise<void> {
    if (!canSave) return;
    setBusy(true);
    setError(null);
    try {
      await updateRecurringBoardTemplate(template.id, {
        poolIds: mix.poolIds,
        manualTaskIds: mix.manualTaskIds,
        removedTaskIds: mix.removedTaskIds,
      });
      onSaved();
    } catch (e) {
      setError(`Could not save: ${(e as Error).message}`);
      setBusy(false);
    }
  }

  return (
    <>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="roster-edit-sheet-title"
        className={styles.backdrop}
        onClick={() => !busy && onClose()}
      >
        <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
          <div className={styles.header}>
            <h3 id="roster-edit-sheet-title" className={styles.title}>
              Edit tasks · {template.name}
            </h3>
            <RisoButton kind="neutral" size="small" onClick={onClose} disabled={busy}>
              Close
            </RisoButton>
          </div>

          <div className={styles.body}>
            <span className={styles.kicker}>Pools</span>
            <p className={styles.helper}>
              Pool tasks union into the mix — toggling a pool off only drops tasks it uniquely
              supplied.
            </p>
            {mix.poolIds.length > 0 && (
              <div className={styles.chips}>
                {mix.poolIds.map((poolId) => {
                  const pool = poolsById[poolId];
                  if (pool === undefined) return null;
                  return (
                    <span key={poolId} className={styles.chip}>
                      {pool.name}
                      <button
                        type="button"
                        className={styles.chipRemove}
                        onClick={() => handleTogglePool(poolId)}
                        disabled={busy}
                        aria-label={`Remove pool ${pool.name}`}
                      >
                        ✕
                      </button>
                    </span>
                  );
                })}
              </div>
            )}
            <button
              type="button"
              className={styles.poolPickerButton}
              onClick={() => setShowPoolPicker(true)}
              disabled={busy}
            >
              {mix.poolIds.length > 0 ? 'Add more pools…' : '+ Pull in a pool…'}
            </button>

            <div className={styles.tasksHeader}>
              <span className={styles.kicker}>Tasks in the mix ({resolvedTasks.length})</span>
            </div>

            {resolvedTasks.length > 0 && (
              <div className={styles.chips}>
                {resolvedTasks.map((task) => {
                  const kind = classifyRosterChip(task.id, mix);
                  return (
                    <span
                      key={task.id}
                      className={kind === 'manual' ? styles.chipManual : styles.chip}
                    >
                      {task.title || '(untitled task)'}
                      <button
                        type="button"
                        className={styles.chipRemove}
                        onClick={() => removeChip(task.id)}
                        disabled={busy}
                        aria-label={`Remove ${task.title || 'task'} from the mix`}
                      >
                        ✕
                      </button>
                    </span>
                  );
                })}
              </div>
            )}

            {remaining > 0 && (
              <p className={styles.floorWarning} role="status">
                Add {remaining} more to save.
              </p>
            )}

            <span className={styles.kicker}>Add tasks</span>
            <div className={styles.quickAddRow}>
              <WizardQuickAddRow
                userId={userId}
                libraryTasks={browsableTasks}
                selectedIds={selectedIdSet}
                onTaskCreated={addTask}
                onExistingTaskPicked={addTask}
                disabled={busy}
              />
            </div>

            <button
              type="button"
              className={styles.libraryToggle}
              onClick={() => setShowLibraryPicker((v) => !v)}
              aria-expanded={showLibraryPicker}
            >
              Reuse a task from your library {showLibraryPicker ? '▴' : '▾'}
            </button>

            {showLibraryPicker && (
              <div className={styles.libraryPicker}>
                <input
                  type="search"
                  className={styles.librarySearch}
                  placeholder="Search your tasks…"
                  value={librarySearch}
                  onChange={(e) => setLibrarySearch(e.target.value)}
                  aria-label="Search your task library"
                />
                <ul className={styles.libraryList}>
                  {libraryResults.length === 0 && (
                    <li className={styles.libraryEmpty}>
                      {librarySearch.trim()
                        ? 'No matches.'
                        : 'Every library task is already in this mix.'}
                    </li>
                  )}
                  {libraryResults.map((task) => (
                    <li key={task.id} className={styles.libraryRow}>
                      <button
                        type="button"
                        className={styles.libraryRowButton}
                        onClick={() => addTask(task)}
                      >
                        <RisoTypeBadge type={task.type} />
                        <span className={styles.libraryRowTitle}>
                          {task.title || '(untitled task)'}
                        </span>
                        <RisoIcon name="plus" size={14} />
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            )}

            {error !== null && (
              <p className={styles.error} role="alert">
                {error}
              </p>
            )}
          </div>

          <div className={styles.footer}>
            <RisoButton kind="neutral" fullWidth onClick={onClose} disabled={busy}>
              Cancel
            </RisoButton>
            <RisoButton
              kind="primary"
              fullWidth
              onClick={() => void handleSave()}
              disabled={!canSave}
              style={{ opacity: canSave ? 1 : 0.45 }}
            >
              Save
            </RisoButton>
          </div>
        </div>
      </div>

      {showPoolPicker && (
        <div className={styles.pickerLayer}>
          <PoolPickerSheet
            userId={userId}
            pools={pools}
            templates={templates}
            tasksById={tasksById}
            browsableTasks={browsableTasks}
            selectedPoolIds={mix.poolIds}
            onTogglePool={handleTogglePool}
            onPoolCreated={handlePoolCreated}
            onClose={() => setShowPoolPicker(false)}
          />
        </div>
      )}
    </>
  );
}
