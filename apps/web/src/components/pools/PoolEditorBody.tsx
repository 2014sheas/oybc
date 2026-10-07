import { useEffect, useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  isSourceSupplyTask,
  type CompoundChild,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { fetchAllBoardTasks, fetchAllCompoundChildren } from '../../db/operations';
import type { TaskEditPatch } from '../../db/taskEditPatch';
import { PoolList } from '../wizard/PoolList';
import { PoolRowEditor } from '../wizard/PoolRowEditor';
import { SpecialTaskPanel } from '../wizard/SpecialTaskPanel';
import { WizardQuickAddRow } from '../wizard/WizardQuickAddRow';
import { RisoButton, RisoIcon, RisoTypeBadge } from '../riso';
import { TasksPoolHeader } from '../wizard/TasksPoolHeader';
import { computeDeckFloor, poolHeaderInputs } from './poolDeckPreview';
import { deletePoolFromSheet, savePoolFromSheet, POOL_NAME_MAX_LENGTH } from './poolEditSheetOps';
import {
  buildPoolEditorView,
  canSavePool,
  dropMemberVary,
  dropStagedEdit,
  groupLinksByCompound,
  pruneMemberVaryToMembers,
  pruneStagedEdits,
  seedEditorDraft,
  setMemberVaryLevel,
  stageEditInto,
} from './poolEditorModel';
import { selectLibraryPickerResults } from './poolEditSheetSelectors';
import styles from './PoolEditorBody.module.css';

const NOOP = (): void => {};

export interface PoolEditorBodyProps {
  /** Authenticated user id — owner of a newly created pool. */
  userId: string;
  /** The pool being edited. `undefined` ⇒ create mode. */
  pool?: Pool;
  /** Active recurring-board templates — the deck-preview line's floor input. */
  templates: RecurringBoardTemplate[];
  /** The user's full non-deleted task library — resolves `taskIds` into rows
   *  (a pool may reference a wizard-born draft task the Library hides; that
   *  reference must still resolve and be removable). */
  allTasks: Task[];
  /** Draft-filtered subset of `allTasks` — the library picker / quick-add
   *  match source (pickers are browse surfaces). */
  browsableTasks: Task[];
  /** Pre-seeds `taskIds` in create mode only; ignored when `pool` is set. */
  initialTaskIds?: string[];
  /** Cancel (discards staged edits; created/reused library tasks stay). */
  onCancel: () => void;
  /** Fired after a successful create/save with the persisted pool. */
  onSaved: (pool: Pool) => void;
  /** Fired after a successful delete (edit mode). */
  onDeleted: () => void;
  /** Reports the mid-write flag so a host (modal Escape / backdrop) can refuse to dismiss. */
  onBusyChange?: (busy: boolean) => void;
  /** Pin the Cancel/Save footer to the bottom of the host's scroll area (modal host). */
  stickyFooter?: boolean;
}

/**
 * PoolEditorBody — the pool editor, shaped like the board wizard's Tasks
 * step: NAME → the wizard's `TasksPoolHeader` card (count / deck floor / deck
 * preview note) → the ADD section (quick-add row, special-type panel) → the
 * dashed library-reuse row → the wizard's resting `PoolList` rows (tap ✎ for
 * the inline `PoolRowEditor`; edits are STAGED here and applied with the
 * membership in one transaction at Save) → Delete pool (edit mode) → Cancel /
 * Save. Hosted by the full-screen `PoolEditorPage` and by the pool picker's
 * "+ Build a new pool…" modal (`PoolEditorModal`). See
 * docs/POOLS_RECURRING.md §Surfaces item 2.
 *
 * Achievements are banned from pools: every ADD surface filters through
 * `isSourceSupplyTask`; a legacy achievement member still renders as a
 * removable row (no pencil).
 */
export function PoolEditorBody({
  userId,
  pool,
  templates,
  allTasks,
  browsableTasks,
  initialTaskIds,
  onCancel,
  onSaved,
  onDeleted,
  onBusyChange,
  stickyFooter = false,
}: PoolEditorBodyProps): React.ReactElement | null {
  const isEdit = pool !== undefined;
  const [name, setName] = useState(pool?.name ?? '');
  // Raw ordered ids — keeps unresolvable ones so a save never prunes them
  // (`Pool.taskIds` contract); rows render only the resolvable subset.
  const [taskIds, setTaskIds] = useState<string[]>(() => pool?.taskIds ?? initialTaskIds ?? []);
  const [sessionTaskCache, setSessionTaskCache] = useState<Map<string, Task>>(() => new Map());
  const [stagedEdits, setStagedEdits] = useState<Map<string, TaskEditPatch>>(() => new Map());

  const [memberVary, setMemberVary] = useState<Record<string, VaryLevel>>(() => pool?.memberVary ?? {});

  const [editingTaskId, setEditingTaskId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState<TaskEditPatch | null>(null);

  const [showLibraryPicker, setShowLibraryPicker] = useState(false);
  const [librarySearch, setLibrarySearch] = useState('');
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    onBusyChange?.(busy);
  }, [busy, onBusyChange]);

  const { ref: deleteConfirmRef, props: deleteConfirmProps } = useModalA11y<HTMLDivElement>({
    open: confirmingDelete,
    onCancel: () => {
      if (!busy) setConfirmingDelete(false);
    },
    initialFocus: 'cancel',
  });

  // Live reads: compound links (row subtitles / sub-task editor) and
  // placements (the usage hint). `undefined` until first resolved.
  const linksQuery = useLiveQuery(() => fetchAllCompoundChildren(), []);
  const boardTasksQuery = useLiveQuery(() => fetchAllBoardTasks(), []);

  const linksByCompound = useMemo(() => {
    const compoundIds = new Set(allTasks.filter((t) => t.type === TaskType.COMPOUND).map((t) => t.id));
    return groupLinksByCompound((linksQuery ?? []).filter((l) => compoundIds.has(l.compoundTaskId)));
  }, [linksQuery, allTasks]);

  const taskBoardCounts = useMemo(() => {
    const buckets = new Map<string, Set<string>>();
    for (const bt of boardTasksQuery ?? []) {
      let set = buckets.get(bt.taskId);
      if (!set) buckets.set(bt.taskId, (set = new Set<string>()));
      set.add(bt.boardId);
    }
    const counts: Record<string, number> = {};
    for (const [id, set] of buckets) counts[id] = set.size;
    return counts;
  }, [boardTasksQuery]);

  const view = useMemo(
    () => buildPoolEditorView(userId, taskIds, allTasks, sessionTaskCache, linksByCompound, stagedEdits),
    [userId, taskIds, allTasks, sessionTaskCache, linksByCompound, stagedEdits],
  );

  const selectedIdSet = useMemo(() => new Set(taskIds), [taskIds]);
  const poolableBrowsableTasks = useMemo(
    () => browsableTasks.filter(isSourceSupplyTask),
    [browsableTasks],
  );
  const libraryResults = useMemo(
    () => selectLibraryPickerResults(poolableBrowsableTasks, selectedIdSet, librarySearch),
    [poolableBrowsableTasks, selectedIdSet, librarySearch],
  );
  // Sub-task quick-add matches (compound editor): browsable tasks with staged edits overlaid.
  const pickerLibraryTasks = useMemo<Task[]>(
    () => browsableTasks.map((t) => view.effectiveTaskMap[t.id] ?? t),
    [browsableTasks, view.effectiveTaskMap],
  );
  const pickerLinks = useMemo<CompoundChild[]>(
    () => Object.values(view.effectiveChildrenByCompound).flat(),
    [view.effectiveChildrenByCompound],
  );

  const deckFloor = useMemo(() => computeDeckFloor(templates, pool?.id ?? ''), [templates, pool?.id]);
  const headerInputs = poolHeaderInputs(
    view.poolTasks.filter(isSourceSupplyTask).length,
    deckFloor,
  );
  const canSave = canSavePool(name, view.poolTasks.length, busy);

  if (linksQuery === undefined || boardTasksQuery === undefined) return null;

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
    setStagedEdits((prev) => dropStagedEdit(prev, taskId));
    setMemberVary((prev) => dropMemberVary(prev, taskId));
    if (editingTaskId === taskId) setEditingTaskId(null);
  }

  function openEditor(taskId: string): void {
    const task = view.effectiveTaskMap[taskId];
    if (!task) return;
    const draft = seedEditorDraft(task, stagedEdits, view.effectiveTaskMap, view.effectiveChildrenByCompound);
    setEditDraft(draft);
    setEditingTaskId(taskId);
  }

  function saveEdit(taskId: string): void {
    if (editDraft) setStagedEdits((prev) => stageEditInto(prev, taskId, editDraft));
    setEditingTaskId(null);
  }

  /** Closing without Save drops the draft; the previously staged patch (if
   *  any) is untouched. No undo toast here — the wizard's toast is its own. */
  function discardEdit(): void {
    setEditingTaskId(null);
  }

  async function handleSave(): Promise<void> {
    if (!canSave) return;
    setBusy(true);
    setError(null);
    try {
      const saved = await savePoolFromSheet(userId, pool, {
        name: name.trim(),
        taskIds,
        stagedEdits: pruneStagedEdits(stagedEdits, taskIds, new Set(view.poolOrder)),
        memberVary: pruneMemberVaryToMembers(memberVary, taskIds),
      });
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

  const libraryQuery = librarySearch.trim();

  return (
    <div className={styles.root}>
      <div className={styles.fields}>
        <label className={styles.kicker} htmlFor="pool-edit-name">
          Name
        </label>
        <input
          id="pool-edit-name"
          type="text"
          autoFocus={!isEdit}
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder='e.g. "Evening wind-down"'
          className={styles.nameInput}
          disabled={busy}
          maxLength={POOL_NAME_MAX_LENGTH}
        />

        <div className={styles.headerBlock}>
          <TasksPoolHeader
            capacity={headerInputs.capacity}
            tasksRequired={headerInputs.tasksRequired}
            note={headerInputs.note}
            isRecurring={false}
            centerTaskMode={false}
            centerSatisfied={false}
          />
        </div>

        <span className={styles.kicker}>Add tasks</span>
        {/* Polling quick-add: typing polls `browsableTasks` for up to 4 reuse
            matches; picking one appends the EXISTING task (no create). */}
        <div className={styles.quickAddCard}>
          <WizardQuickAddRow
            userId={userId}
            libraryTasks={poolableBrowsableTasks}
            selectedIds={selectedIdSet}
            onTaskCreated={addTask}
            onExistingTaskPicked={addTask}
            disabled={busy}
          />
        </div>
        {/* The SAME inline special-type panel the board wizard uses
            (interface-consistency rule). Immediate persist: a created task is
            a real library task at once and lands in the pool via `addTask`. */}
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
                  <button type="button" className={styles.libraryRowButton} onClick={() => addTask(task)}>
                    <RisoTypeBadge type={task.type} />
                    <span className={styles.libraryRowTitle}>{task.title || '(untitled task)'}</span>
                    <RisoIcon name="plus" size={14} />
                  </button>
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className={styles.listBlock}>
          <PoolList
            surface="pool"
            poolOrder={view.poolOrder}
            effectiveTaskMap={view.effectiveTaskMap}
            effectiveChildrenByCompound={view.effectiveChildrenByCompound}
            taskBoardCounts={taskBoardCounts}
            centerTaskMode={false}
            centerTaskId={null}
            onCenterClick={NOOP}
            onRemove={removeTask}
            manualTaskVary={memberVary}
            onSetManualVary={(id, level) => setMemberVary((prev) => setMemberVaryLevel(prev, id, level))}
            editingTaskId={editingTaskId}
            onEdit={openEditor}
            editor={(task) =>
              editDraft && (
                <PoolRowEditor
                  task={task}
                  draft={editDraft}
                  onDraftChange={setEditDraft}
                  onSave={() => saveEdit(task.id)}
                  onDiscard={discardEdit}
                  libraryTasks={pickerLibraryTasks}
                  allLinks={pickerLinks}
                />
              )
            }
          />
        </div>

        {error !== null && (
          <p className={styles.error} role="alert">
            {error}
          </p>
        )}
      </div>

      <div className={`${styles.footer} ${stickyFooter ? styles.footerSticky : ''}`}>
        {/* Stays mounted while the confirm shows so Escape hands focus back to it. */}
        {isEdit && (
          <button
            type="button"
            className={styles.deleteLink}
            onClick={() => setConfirmingDelete(true)}
            disabled={busy}
            aria-expanded={confirmingDelete}
          >
            Delete pool
          </button>
        )}

        {confirmingDelete && (
          <div
            ref={deleteConfirmRef}
            className={styles.deleteConfirm}
            role="alertdialog"
            aria-label="Confirm delete pool"
            {...deleteConfirmProps}
          >
            <p className={styles.deleteConfirmBody}>
              Delete &quot;{pool?.name}&quot;? It detaches from any repeating boards and core
              defaults that draw from it — tasks are never deleted.
            </p>
            <div className={styles.deleteConfirmActions}>
              <RisoButton
                kind="neutral"
                size="small"
                data-modal-cancel
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
          <RisoButton kind="neutral" fullWidth onClick={onCancel} disabled={busy}>
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
  );
}
