import { useEffect, useMemo, useState } from 'react';
import { isSourceSupplyTask, type Pool, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { SpecialTaskPanel } from '../wizard/SpecialTaskPanel';
import { WizardQuickAddRow } from '../wizard/WizardQuickAddRow';
import { RisoButton, RisoIcon, RisoTypeBadge } from '../riso';
import { computeDeckFloor, formatDeckPreview } from './poolDeckPreview';
import { deletePoolFromSheet, savePoolFromSheet, POOL_NAME_MAX_LENGTH } from './poolEditSheetOps';
import { resolvePoolChips, selectLibraryPickerResults } from './poolEditSheetSelectors';
import styles from './PoolEditSheet.module.css';

export interface PoolEditSheetProps {
  /** Authenticated user id — owner of a newly created pool. */
  userId: string;
  /** The pool being edited. `undefined` ⇒ create mode ("New pool"). */
  pool?: Pool;
  /** Active recurring-board templates (spawn records) — used only to
   *  compute the deck-preview line's floor (§POOLS_RECURRING.md Surfaces
   *  item 2: "smallest consuming floor, else the 3×3-FREE default 8"). */
  templates: RecurringBoardTemplate[];
  /** The user's full non-deleted task library — resolves `taskIds` into
   *  chip titles/types. NOT the picker's source list (see
   *  `browsableTasks`): a pool may reference a wizard-born draft task
   *  that the Library hides, and that reference must still resolve to a
   *  visible chip here. */
  allTasks: Task[];
  /** Draft-filtered subset of `allTasks` (`useTasksFilters`'
   *  `browsableTasks`) — the "Reuse a task from your library" picker's
   *  source list (P2 I-2). Pickers are browse surfaces: they shouldn't
   *  offer a wizard-born draft task the Library tab itself hides. */
  browsableTasks: Task[];
  /**
   * P3 (Task Pools + Recurring Boards Rework, wizard "Save these N as a
   * new pool…") — pre-seeds `taskIds` in CREATE mode only (`pool ===
   * undefined`); ignored in edit mode, where `pool.taskIds` always wins.
   * Callers should already exclude ids that can't yet resolve to a
   * persisted task (e.g. the wizard's in-memory Bug #85 pending tasks) —
   * this sheet doesn't re-filter.
   */
  initialTaskIds?: string[];
  /** Backdrop click / Escape / Cancel / Close. */
  onClose: () => void;
  /** Fired after a successful create or save, with the persisted `Pool`.
   *  P7's `PoolPickerSheet` uses the argument to select the newly-created
   *  pool in the launching context ("+ Build a new pool…" round-trips back
   *  with the new pool selected) — existing callers that only care about
   *  closing the sheet can keep passing a zero-arg `() => void` (a
   *  function with fewer declared params is assignable to a callback type
   *  expecting more; JS ignores the extra argument). */
  onSaved: (pool: Pool) => void;
  /** Fired after a successful delete. */
  onDeleted: () => void;
}

/**
 * PoolEditSheet — the Tasks-tab pool editor (Task Pools + Recurring Boards
 * Rework, P2). Extends the iOS `PoolEditSheet` baseline for the new `Pool`
 * entity: a NAME field replaces the old timeframe-keyed FEEDS segmented.
 * Task creation follows the interface-consistency rule (owner directive
 * 2026-09-10): the SAME quick-add row + inline `SpecialTaskPanel` pair
 * the board wizard's Tasks step uses — the earlier "New task" button +
 * stacked `NewTaskSheet` modal (Tasks-tab lineage) hid the pool being
 * built and used a different vocabulary for the same job. The
 * "reuse a task from your library" picker below remains. See
 * docs/POOLS_RECURRING.md §Surfaces item 2.
 *
 * The ADD TASKS section pairs the Normal-only `WizardQuickAddRow` (now with
 * library polling — owner decision 2026-07-21: typing polls
 * `browsableTasks` and offers up to 4 reuse matches inline, so a duplicate
 * title reuses the existing task instead of creating a new one) ABOVE the
 * special-type panel (`allowAchievement={false}` — achievements are banned
 * from pools, owner decision 2026-09-10; every ADD surface here filters
 * through `isSourceSupplyTask`). The "Reuse a task from your library"
 * browse-all picker below remains for finding a match without typing its
 * exact title. Every
 * created/reused task is a real, immediately-persisted library task (no
 * `createdInWizard` flag — this sheet isn't a board wizard) that lands in
 * the pool via the shared `addTask` append-to-pool handler.
 *
 * NO board-related actions render here (locked decision) — this sheet
 * only populates the pool; boards pull pools in from the wizard side.
 *
 * Modeled on `CreateCounterSheet` / `NewTaskSheet`'s chrome (backdrop +
 * `role="dialog"` panel); owns its own field state directly since there's
 * no parent form to lift into, mirroring `CreateCounterSheet`'s pattern.
 * Mounted only while open (see `PoolsBrowse`), so — unlike
 * `CreateCounterSheet`, which stays mounted and resets on an `open` flag —
 * this component just initializes state once from `pool` via lazy
 * `useState` and lets a fresh mount reset it.
 */
export function PoolEditSheet({
  userId,
  pool,
  templates,
  allTasks,
  browsableTasks,
  initialTaskIds,
  onClose,
  onSaved,
  onDeleted,
}: PoolEditSheetProps): React.ReactElement {
  const isEdit = pool !== undefined;

  const [name, setName] = useState(pool?.name ?? '');
  // Raw id list, in order — includes ids that don't resolve against
  // `allTasks` (soft-deleted or otherwise missing) so a save preserves
  // them per `Pool.taskIds`'s docstring contract (consumers filter at
  // read time; a write must never prune). Chips/counts below render only
  // the RESOLVABLE subset — never this list directly. `initialTaskIds`
  // (P3) only applies in create mode — `pool?.taskIds` always wins when
  // editing an existing pool.
  const [taskIds, setTaskIds] = useState<string[]>(() => pool?.taskIds ?? initialTaskIds ?? []);
  // Supplements `allTasks` for freshly quick-added/library-picked tasks
  // that may not have round-tripped through the `allTasks` prop's live
  // query yet — sidesteps a title flash. Never the persistence source.
  const [sessionTaskCache, setSessionTaskCache] = useState<Map<string, Task>>(
    () => new Map(),
  );

  const [showLibraryPicker, setShowLibraryPicker] = useState(false);
  const [librarySearch, setLibrarySearch] = useState('');
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Escape-to-cancel, mirroring `CreateCounterSheet`. Guards against
  // dismissing mid-write. (The old "New task" modal's extra Escape guard
  // went with the modal — the special-type panel is inline, so there's no
  // stacked sheet to double-dismiss anymore.)
  useEffect(() => {
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape' && !busy) onClose();
    }
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose, busy]);

  const trimmedName = name.trim();
  const tasksById = useMemo(() => new Map(allTasks.map((t) => [t.id, t] as const)), [allTasks]);
  const selectedIdSet = useMemo(() => new Set(taskIds), [taskIds]);
  // The resolvable subset of `taskIds`, in `taskIds` order — this (never
  // the raw id list) is what "TASKS (N)", the chip row, and the deck
  // preview render, matching `computePoolHealth`'s "resolvable, non-
  // deleted" count semantics (P2 I-3).
  const poolTasks = useMemo(
    () => resolvePoolChips(taskIds, tasksById, sessionTaskCache),
    [taskIds, tasksById, sessionTaskCache],
  );
  const canSave = trimmedName !== '' && poolTasks.length > 0 && !busy;

  const deckFloor = useMemo(
    () => computeDeckFloor(templates, pool?.id ?? ''),
    [templates, pool?.id],
  );
  // The preview line is a claim about what boards can PULL, so it counts
  // supply-eligible tasks only (achievements are banned from supply) —
  // while "TASKS (N)" and the chip row above stay what-you-see, including
  // a removable legacy achievement chip.
  const supplyCount = poolTasks.filter(isSourceSupplyTask).length;
  const deckPreviewText = formatDeckPreview(supplyCount, deckFloor);

  // Achievements are banned from pools (owner decision 2026-09-10; the
  // supply-side twin is `isSourceSupplyTask` in the source resolvers) —
  // every ADD surface on this sheet filters them out. `allTasks` stays
  // unfiltered so a legacy achievement already in `taskIds` still
  // resolves to a removable chip rather than vanishing silently.
  const poolableBrowsableTasks = useMemo(
    () => browsableTasks.filter(isSourceSupplyTask),
    [browsableTasks],
  );

  const libraryQuery = librarySearch.trim().toLowerCase();
  const libraryResults = useMemo(
    () => selectLibraryPickerResults(poolableBrowsableTasks, selectedIdSet, librarySearch),
    [poolableBrowsableTasks, selectedIdSet, librarySearch],
  );

  function addTask(task: Task): void {
    setTaskIds((ids) => (ids.includes(task.id) ? ids : [...ids, task.id]));
    setSessionTaskCache((cache) => {
      if (cache.get(task.id) === task) return cache;
      const next = new Map(cache);
      next.set(task.id, task);
      return next;
    });
  }

  function removeTask(taskId: string): void {
    setTaskIds((ids) => ids.filter((id) => id !== taskId));
  }

  async function handleSave(): Promise<void> {
    if (!canSave) return;
    setBusy(true);
    setError(null);
    try {
      // Write the raw (possibly-includes-unresolvable) id list, minus any
      // explicit removals and plus any additions — never the resolved
      // display subset — so a stale/soft-deleted reference the user never
      // touched survives the save (Pool.taskIds docstring contract).
      const saved = await savePoolFromSheet(userId, pool, { name: trimmedName, taskIds });
      onSaved(saved);
    } catch (e) {
      setError(`Could not save pool: ${(e as Error).message}`);
      setBusy(false);
    }
  }

  async function handleDelete(): Promise<void> {
    if (!pool || busy) return;
    setBusy(true);
    setError(null);
    try {
      await deletePoolFromSheet(pool);
      onDeleted();
    } catch (e) {
      setError(`Could not delete pool: ${(e as Error).message}`);
      setBusy(false);
    }
  }

  return (
    <>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="pool-edit-sheet-title"
        className={styles.backdrop}
        onClick={() => !busy && onClose()}
      >
      <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div className={styles.header}>
          <h3 id="pool-edit-sheet-title" className={styles.title}>
            {isEdit ? 'Edit pool' : 'New pool'}
          </h3>
          <RisoButton kind="neutral" size="small" onClick={onClose} disabled={busy}>
            Close
          </RisoButton>
        </div>

        <div className={styles.body}>
          <label className={styles.kicker} htmlFor="pool-edit-name">
            Name
          </label>
          <input
            id="pool-edit-name"
            type="text"
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder='e.g. "Evening wind-down"'
            className={styles.nameInput}
            disabled={busy}
            maxLength={POOL_NAME_MAX_LENGTH}
          />

          <div className={styles.tasksHeader}>
            <span className={styles.kicker}>Tasks ({poolTasks.length})</span>
          </div>
          <p className={styles.helper}>
            Add a few tasks — boards pull their squares from this list.
          </p>

          {poolTasks.length > 0 && (
            <div className={styles.chips}>
              {poolTasks.map((task) => (
                <span key={task.id} className={styles.chip}>
                  {task.title || '(untitled task)'}
                  <button
                    type="button"
                    className={styles.chipRemove}
                    onClick={() => removeTask(task.id)}
                    disabled={busy}
                    aria-label={`Remove ${task.title || 'task'} from pool`}
                  >
                    ✕
                  </button>
                </span>
              ))}
            </div>
          )}

          <span className={styles.kicker}>Add tasks</span>
          {/* Polling quick-add — re-added (P5.x, owner decision 2026-07-21)
              ABOVE the "New task" button. Typing polls `browsableTasks` for
              up to 4 reuse matches; picking one appends the EXISTING task
              via `addTask` (no create). Enter/Add still creates a new
              Normal task, same as the board wizard's row. */}
          <div className={styles.quickAddRow}>
            <WizardQuickAddRow
              userId={userId}
              libraryTasks={poolableBrowsableTasks}
              selectedIds={selectedIdSet}
              onTaskCreated={addTask}
              onExistingTaskPicked={addTask}
              disabled={busy}
            />
          </div>
          {/* Interface-consistency rule (owner directive 2026-09-10) —
              the SAME inline special-type panel the board wizard's Tasks
              step uses, replacing the old "New task" button + stacked
              modal (which hid the pool being built). Immediate persist
              (no `onPendingCreated`): this sheet is not a board wizard,
              so a created task is a real library task at once; compounds
              land in the pool like any other type. */}
          <SpecialTaskPanel
            userId={userId}
            allowAchievement={false}
            submitLabel="Add to pool ✦"
            onTaskCreated={addTask}
            onCompoundCreated={addTask}
            suggestionPool={allTasks}
          />

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
                    {libraryQuery ? 'No matches.' : 'Every library task is already in this pool.'}
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

          <p className={styles.deckPreview}>{deckPreviewText}</p>

          {error !== null && (
            <p className={styles.error} role="alert">
              {error}
            </p>
          )}
        </div>

        <div className={styles.footer}>
          {isEdit && !confirmingDelete && (
            <button
              type="button"
              className={styles.deleteLink}
              onClick={() => setConfirmingDelete(true)}
              disabled={busy}
            >
              Delete pool
            </button>
          )}

          {confirmingDelete && (
            <div className={styles.deleteConfirm} role="alertdialog" aria-label="Confirm delete pool">
              <p className={styles.deleteConfirmBody}>
                Delete &quot;{pool?.name}&quot;? It detaches from any repeating boards and core
                defaults that draw from it — tasks are never deleted.
              </p>
              <div className={styles.deleteConfirmActions}>
                <RisoButton
                  kind="neutral"
                  size="small"
                  onClick={() => setConfirmingDelete(false)}
                  disabled={busy}
                >
                  Cancel
                </RisoButton>
                <RisoButton kind="primary" size="small" onClick={() => void handleDelete()} disabled={busy}>
                  Delete
                </RisoButton>
              </div>
            </div>
          )}

          <div className={styles.actions}>
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
              {isEdit ? 'Save' : 'Create pool'}
            </RisoButton>
          </div>
        </div>
      </div>
      </div>

    </>
  );
}
