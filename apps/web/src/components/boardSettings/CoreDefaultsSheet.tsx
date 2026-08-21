import { useEffect, useMemo, useState } from 'react';
import { Timeframe, type CoreBoardDefault, type Pool, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { upsertCoreBoardDefault } from '../../db/operations/coreBoardDefaults';
import { WizardQuickAddRow } from '../wizard/WizardQuickAddRow';
import { RisoButton, RisoIcon, RisoTypeBadge } from '../riso';
import { selectLibraryPickerResults } from '../pools/poolEditSheetSelectors';
import { PoolPickerSheet } from '../pools/PoolPickerSheet';
import styles from './CoreDefaultsSheet.module.css';

const TIMEFRAME_LABEL: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom', // unreachable — core defaults exclude custom
  [Timeframe.INDEFINITE]: 'Ongoing', // unreachable
};

export interface CoreDefaultsSheetProps {
  /** Authenticated user id — inherited by quick-added tasks and the saved row. */
  userId: string;
  /** The timeframe this default row governs. Immutable post-create. */
  timeframe: Timeframe;
  /** The existing `CoreBoardDefault` row, or `undefined` when the user
   *  hasn't set one up yet for this timeframe. */
  existingDefault: CoreBoardDefault | undefined;
  /** The user's non-deleted pools — for the pool-picker sheet. */
  pools: Pool[];
  /** Active repeating boards — the pool picker's health-note input. */
  templates: RecurringBoardTemplate[];
  /** The user's full non-deleted task library — resolves ids to chips. */
  allTasks: Task[];
  /** Draft-filtered subset of `allTasks` — the library-reuse picker's
   *  source list. */
  browsableTasks: Task[];
  /** Backdrop click / Escape / Cancel / Close. */
  onClose: () => void;
  /** Fired after a successful save. */
  onSaved: () => void;
}

/**
 * CoreDefaultsSheet — the Board-settings per-timeframe defaults sheet
 * (Task Pools + Recurring Boards Rework, P7, docs/POOLS_RECURRING.md
 * §Surfaces item 9). Authors a `CoreBoardDefault` row for ONE timeframe:
 * `corePoolIds` via the shared pool-picker sheet (item 10) and
 * `coreDefaultTaskIds` via chips + quick-add — this sheet is the FIRST
 * writer of `coreDefaultTaskIds` (P1 shipped the field synced-but-unwritten;
 * P5's core-setup prefill already reads it via `applyCoreBoardDefaultPrefill`,
 * it just had nothing to read until now).
 *
 * No fillable-floor gate here (unlike the roster edit sheet): defaults are
 * an optional PREFILL, not an activation gate — an empty selection is a
 * valid save (it just means "no default tasks" going forward).
 *
 * Both fields save together via `upsertCoreBoardDefault(userId, timeframe,
 * {corePoolIds, coreDefaultTaskIds})` in one call.
 */
export function CoreDefaultsSheet({
  userId,
  timeframe,
  existingDefault,
  pools,
  templates,
  allTasks,
  browsableTasks,
  onClose,
  onSaved,
}: CoreDefaultsSheetProps): React.ReactElement {
  const [corePoolIds, setCorePoolIds] = useState<string[]>(() => existingDefault?.corePoolIds ?? []);
  const [coreDefaultTaskIds, setCoreDefaultTaskIds] = useState<string[]>(
    () => existingDefault?.coreDefaultTaskIds ?? [],
  );
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

  const defaultTasks = useMemo(
    () => coreDefaultTaskIds.map((id) => tasksById[id]).filter((t): t is Task => t !== undefined),
    [coreDefaultTaskIds, tasksById],
  );
  const selectedIdSet = useMemo(() => new Set(coreDefaultTaskIds), [coreDefaultTaskIds]);
  const libraryResults = useMemo(
    () => selectLibraryPickerResults(browsableTasks, selectedIdSet, librarySearch),
    [browsableTasks, selectedIdSet, librarySearch],
  );

  function handleTogglePool(poolId: string): void {
    setCorePoolIds((prev) =>
      prev.includes(poolId) ? prev.filter((id) => id !== poolId) : [...prev, poolId],
    );
  }

  function handlePoolCreated(pool: Pool): void {
    void pool; // selection is applied by PoolPickerSheet's own onTogglePool call
  }

  function addTask(task: Task): void {
    setSessionTaskCache((cache) => {
      if (cache.get(task.id) === task) return cache;
      const next = new Map(cache);
      next.set(task.id, task);
      return next;
    });
    setCoreDefaultTaskIds((ids) => (ids.includes(task.id) ? ids : [...ids, task.id]));
  }

  function removeTask(taskId: string): void {
    setCoreDefaultTaskIds((ids) => ids.filter((id) => id !== taskId));
  }

  async function handleSave(): Promise<void> {
    setBusy(true);
    setError(null);
    try {
      await upsertCoreBoardDefault(userId, timeframe, { corePoolIds, coreDefaultTaskIds });
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
        aria-labelledby="core-defaults-sheet-title"
        className={styles.backdrop}
        onClick={() => !busy && onClose()}
      >
        <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
          <div className={styles.header}>
            <h3 id="core-defaults-sheet-title" className={styles.title}>
              {TIMEFRAME_LABEL[timeframe]} defaults
            </h3>
            <RisoButton kind="neutral" size="small" onClick={onClose} disabled={busy}>
              Close
            </RisoButton>
          </div>

          <div className={styles.body}>
            <p className={styles.intro}>
              Pre-fill every new {TIMEFRAME_LABEL[timeframe].toLowerCase()} board's setup with
              these pools and tasks. You can still add or remove tasks before saving each board.
            </p>

            <span className={styles.kicker}>Pools</span>
            {corePoolIds.length > 0 && (
              <div className={styles.chips}>
                {corePoolIds.map((poolId) => {
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
              {corePoolIds.length > 0 ? 'Add more pools…' : '+ Start with a pool…'}
            </button>

            <div className={styles.tasksHeader}>
              <span className={styles.kicker}>Default tasks ({defaultTasks.length})</span>
            </div>
            {defaultTasks.length === 0 && (
              <p className={styles.helper}>No default tasks yet — add some below.</p>
            )}
            {defaultTasks.length > 0 && (
              <div className={styles.chips}>
                {defaultTasks.map((task) => (
                  <span key={task.id} className={styles.chip}>
                    {task.title || '(untitled task)'}
                    <button
                      type="button"
                      className={styles.chipRemove}
                      onClick={() => removeTask(task.id)}
                      disabled={busy}
                      aria-label={`Remove ${task.title || 'task'} from defaults`}
                    >
                      ✕
                    </button>
                  </span>
                ))}
              </div>
            )}

            <span className={styles.kicker}>Add tasks</span>
            <div className={styles.quickAddRow}>
              <WizardQuickAddRow
                userId={userId}
                currentTimeframe={timeframe}
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
                        : 'Every library task is already a default.'}
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
            <RisoButton kind="primary" fullWidth onClick={() => void handleSave()} disabled={busy}>
              {busy ? 'Saving…' : 'Save'}
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
            selectedPoolIds={corePoolIds}
            onTogglePool={handleTogglePool}
            onPoolCreated={handlePoolCreated}
            onClose={() => setShowPoolPicker(false)}
          />
        </div>
      )}
    </>
  );
}
