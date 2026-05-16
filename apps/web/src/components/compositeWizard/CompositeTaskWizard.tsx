import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  OperatorType,
  TaskType,
  type Task,
  type BoardTask,
  type CompoundChild,
  type CreateCompoundChildEntry,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createCompound } from '../../db/operations/tasks';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from '../playground/playgroundUtils';
import { type StepFormState, createEmptyStep } from '../progressStepUtils';
import {
  CompositeWizardStepper,
  type CompositeWizardStep,
} from './CompositeWizardStepper';
import { SetupStep } from './SetupStep';
import { BuildStep } from './BuildStep';
import { ReviewStep } from './ReviewStep';
import { TaskDetailSheet } from '../TaskDetailSheet';
import {
  type SubtaskDraft,
  type ExistingSubtaskDraft,
  type InlineSubtaskDraft,
} from './compositeSubtaskDraft';
import styles from './CompositeTaskWizard.module.css';

// Stable empty fallbacks for `?? FALLBACK` — see BoardPlayPage.tsx for rationale.
const EMPTY_TASKS = Object.freeze([]) as unknown as Task[];
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
const EMPTY_COMPOUND_CHILDREN = Object.freeze([]) as unknown as CompoundChild[];

export interface CompositeTaskWizardProps {
  /** User ID for task ownership. Defaults to playground user when omitted. */
  userId?: string;
  /** Invoked with the newly created compound Task after a successful save. */
  onCreated?: (task: Task) => void;
}

function createExistingSubtask(id: string, kind: 'task' | 'composite'): ExistingSubtaskDraft {
  return {
    id: crypto.randomUUID(),
    mode: 'existing',
    selectionType: kind,
    selectedId: id,
  };
}

function createEmptyInlineSubtask(): InlineSubtaskDraft {
  return {
    id: crypto.randomUUID(),
    mode: 'inline',
    inlineType: 'normal',
    title: '',
    action: '',
    unit: '',
    maxCountStr: '',
    steps: [createEmptyStep()],
  };
}

/**
 * CompositeTaskWizard — 3-step mini-wizard (Setup → Build → Review) that
 * creates compound tasks using the unified compound model (db.tasks +
 * db.compoundChildren). Legacy composite/progress tables are no longer used.
 *
 * State is deliberately kept in one place rather than split across a
 * hook for stage 2 — simpler to read and reason about while the wizard
 * is under active iteration. A hook extraction is on the table if a
 * third consumer needs the same state shape later.
 */
export function CompositeTaskWizard({
  userId,
  onCreated,
}: CompositeTaskWizardProps = {}): React.ReactElement {
  const resolvedUserId = userId ?? PLAYGROUND_USER_ID;

  // Core form state
  const [title, setTitle] = useState('');
  const [operator, setOperator] = useState<OperatorType>(OperatorType.AND);
  const [threshold, setThreshold] = useState(2);
  const [subtasks, setSubtasks] = useState<SubtaskDraft[]>([]);

  // UI state
  const [currentStep, setCurrentStep] = useState<CompositeWizardStep>(1);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  /** When set, mounts the TaskDetailSheet over the wizard so the user can
   *  inspect a referenced subtask without losing wizard state. Replace
   *  semantics inside the sheet — see TaskDetailSheet props. */
  const [openedTaskInLibrary, setOpenedTaskInLibrary] = useState<string | null>(null);

  // Library feeds — live so a task created elsewhere shows up here.
  // Use JS-level .filter() (same pattern as the useTasks hook) so the boolean
  // `isDeleted` matches across both new compound rows (stored as `false`) and
  // legacy migrated rows (stored as `0`). Indexing-level `equals([..., 0])`
  // breaks for new rows because Dexie compound-index match is strict-equal,
  // and `false !== 0`.
  const allTasks = useLiveQuery(
    () =>
      db.tasks
        .filter((t) => t.userId === resolvedUserId && !t.isDeleted && t.type !== TaskType.COMPOUND)
        .toArray(),
    [resolvedUserId],
  ) ?? EMPTY_TASKS;

  // Compound tasks in the library (formerly "compositeTasks").
  const allCompoundTasks: Task[] = useLiveQuery(
    () =>
      db.tasks
        .filter((t) => t.userId === resolvedUserId && !t.isDeleted && t.type === TaskType.COMPOUND)
        .toArray(),
    [resolvedUserId],
  ) ?? EMPTY_TASKS;

  // Usage hints for the existing-task picker.
  const allBoardTasks = useLiveQuery(() => db.boardTasks.toArray(), []) ?? EMPTY_BOARD_TASKS;

  // compoundChildren — used to compute child counts + leaf previews for compound tasks.
  const allCompoundChildren: CompoundChild[] = useLiveQuery(
    () => db.compoundChildren.filter((c) => !c.isDeleted).toArray(),
    [],
  ) ?? EMPTY_COMPOUND_CHILDREN;

  /** taskId → count of distinct board IDs it's placed on. */
  const taskBoardCounts = useMemo(() => {
    const buckets = new Map<string, Set<string>>();
    for (const bt of allBoardTasks) {
      let set = buckets.get(bt.taskId);
      if (!set) {
        set = new Set<string>();
        buckets.set(bt.taskId, set);
      }
      set.add(bt.boardId);
    }
    const counts: Record<string, number> = {};
    for (const [taskId, set] of buckets) counts[taskId] = set.size;
    return counts;
  }, [allBoardTasks]);

  /**
   * compoundTaskId → count of non-deleted direct children.
   * Replaces the legacy compositeSubtaskCounts (which counted composite nodes).
   */
  const compoundChildCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const child of allCompoundChildren) {
      counts[child.compoundTaskId] = (counts[child.compoundTaskId] ?? 0) + 1;
    }
    return counts;
  }, [allCompoundChildren]);

  /**
   * compoundTaskId → first few child task titles + total count.
   * Drives the "Run 5km, Meditate, +2 more" subtitle in the picker.
   * Progress-task step counts are no longer surfaced — progress tasks have
   * been unified into the compound model and no longer carry taskSteps rows.
   */
  const compoundLeafPreviews = useMemo(() => {
    const previews: Record<string, { titles: string[]; totalLeaves: number }> = {};
    const taskTitleById = new Map<string, string>();
    for (const t of allTasks) taskTitleById.set(t.id, t.title);
    for (const ct of allCompoundTasks) taskTitleById.set(ct.id, ct.title);

    // Group children by compound, ordered by childIndex.
    const childrenByCompound = new Map<string, CompoundChild[]>();
    for (const child of allCompoundChildren) {
      const arr = childrenByCompound.get(child.compoundTaskId) ?? [];
      arr.push(child);
      childrenByCompound.set(child.compoundTaskId, arr);
    }

    for (const [compoundId, children] of childrenByCompound) {
      children.sort((a, b) => a.childIndex - b.childIndex);
      const titles: string[] = [];
      for (const child of children.slice(0, 3)) {
        const t = taskTitleById.get(child.childTaskId);
        if (t) titles.push(t);
      }
      previews[compoundId] = { titles, totalLeaves: children.length };
    }
    return previews;
  }, [allCompoundChildren, allTasks, allCompoundTasks]);

  // taskStepCounts is no longer meaningful after the v5 migration (taskSteps
  // table was dropped). Pass an empty map so downstream components compile;
  // the "N steps" subtitle will simply not appear, which is correct — progress
  // tasks are now compound tasks and their children appear via compoundChildren.
  const taskStepCounts: Record<string, number> = {};

  // ─── State helpers ────────────────────────────────────────────────────────────

  function addInlineSubtask(): void {
    setSubtasks((prev) => [...prev, createEmptyInlineSubtask()]);
  }

  /** Toggle one library item in/out of the composite. If an
   *  existing-mode draft already points at `id`, remove it; otherwise
   *  append a fresh draft. Inline drafts are untouched. Threshold
   *  clamping is handled by BuildStep's effect, so this stays a pure
   *  state update. */
  function toggleLibraryItem(id: string, kind: 'task' | 'composite'): void {
    setSubtasks((prev) => {
      const alreadyIdx = prev.findIndex(
        (s) => s.mode === 'existing' && s.selectedId === id,
      );
      if (alreadyIdx !== -1) {
        return prev.filter((_, i) => i !== alreadyIdx);
      }
      return [...prev, createExistingSubtask(id, kind)];
    });
  }

  function removeSubtask(id: string): void {
    setSubtasks((prev) => prev.filter((s) => s.id !== id));
  }

  function updateSubtask(id: string, updates: Partial<SubtaskDraft>): void {
    setSubtasks((prev) =>
      prev.map((s) => (s.id === id ? ({ ...s, ...updates } as SubtaskDraft) : s)),
    );
  }

  function updateInlineStep(subtaskId: string, stepId: string, field: keyof StepFormState, value: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return {
          ...s,
          steps: s.steps.map((step) => (step.id === stepId ? { ...step, [field]: value } : step)),
        };
      }),
    );
  }

  function addStep(subtaskId: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return { ...s, steps: [...s.steps, createEmptyStep()] };
      }),
    );
  }

  function removeStep(subtaskId: string, stepId: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return { ...s, steps: s.steps.filter((step) => step.id !== stepId) };
      }),
    );
  }

  function resetForm(): void {
    setTitle('');
    setOperator(OperatorType.AND);
    setThreshold(2);
    setSubtasks([]);
    setCurrentStep(1);
    setErrorMessage(null);
  }

  // ─── Submit ───────────────────────────────────────────────────────────────────

  /**
   * Build a CreateCompoundTaskInput from the wizard's form state and delegate
   * to createCompound() from db/operations/tasks.ts. That function writes
   * everything atomically (tasks + compoundChildren) in one Dexie transaction.
   *
   * Inline progress-subtask creation is intentionally not supported here:
   * CreateCompoundChildEntry.autoCreate only accepts 'normal' | 'counting',
   * matching the current createCompound spec. Users should create an inner
   * compound task first, then reference it as an existing child.
   * TODO (Phase 5/8): revisit inline nested compound creation when the spec
   * defines the UX for editing nested compounds.
   */
  async function handleCreate(): Promise<void> {
    setErrorMessage(null);
    setIsSubmitting(true);
    try {
      const children: CreateCompoundChildEntry[] = subtasks.map((subtask) => {
        if (subtask.mode === 'existing') {
          return { childTaskId: subtask.selectedId };
        }

        // Inline-created subtask — map to autoCreate shape.
        // Progress inline subtasks are treated as 'normal' for now (see TODO above).
        if (subtask.inlineType === 'counting') {
          const maxCount = parseInt(subtask.maxCountStr, 10);
          const trimmedAction = subtask.action.trim();
          const trimmedUnit = subtask.unit.trim();
          return {
            autoCreate: {
              type: TaskType.COUNTING,
              title: subtask.title.trim(),
              action: trimmedAction || undefined,
              unit: trimmedUnit || undefined,
              maxCount: Number.isFinite(maxCount) ? maxCount : undefined,
            },
          };
        }

        // 'normal' or 'progress' (progress falls back to normal — see TODO above)
        return {
          autoCreate: {
            type: TaskType.NORMAL,
            title: subtask.title.trim(),
          },
        };
      });

      const compound = await createCompound(resolvedUserId, {
        title: title.trim(),
        operator,
        threshold: operator === OperatorType.M_OF_N ? threshold : undefined,
        isOrdered: false,
        children,
      });

      setSuccessMessage('Composite task created!');
      onCreated?.(compound);
      resetForm();
      setTimeout(() => setSuccessMessage(null), SUCCESS_DISMISS_MS);
    } catch (err) {
      setErrorMessage(`Failed: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsSubmitting(false);
    }
  }

  // ─── Render ───────────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <CompositeWizardStepper
        currentStep={currentStep}
        onStepClick={(step) => {
          if (step < currentStep) setCurrentStep(step);
        }}
      />

      {currentStep === 1 && (
        <SetupStep
          title={title}
          onTitleChange={setTitle}
          operator={operator}
          onOperatorChange={setOperator}
          onCancel={resetForm}
          onNext={() => setCurrentStep(2)}
        />
      )}

      {currentStep === 2 && (
        <BuildStep
          subtasks={subtasks}
          operator={operator}
          threshold={threshold}
          onThresholdChange={setThreshold}
          allTasks={allTasks}
          allCompositeTasks={allCompoundTasks}
          taskBoardCounts={taskBoardCounts}
          taskStepCounts={taskStepCounts}
          compositeSubtaskCounts={compoundChildCounts}
          compositeLeafPreviews={compoundLeafPreviews}
          onUpdateSubtask={updateSubtask}
          onRemoveSubtask={removeSubtask}
          onStepFieldChange={updateInlineStep}
          onAddStep={addStep}
          onRemoveStep={removeStep}
          onToggleLibraryItem={toggleLibraryItem}
          onAddInline={addInlineSubtask}
          onBack={() => setCurrentStep(1)}
          onNext={() => setCurrentStep(3)}
          onOpenTask={(id) => setOpenedTaskInLibrary(id)}
        />
      )}

      {currentStep === 3 && (
        <ReviewStep
          title={title}
          operator={operator}
          threshold={threshold}
          subtasks={subtasks}
          allTasks={allTasks}
          allCompositeTasks={allCompoundTasks}
          isSubmitting={isSubmitting}
          errorMessage={errorMessage}
          onBack={() => setCurrentStep(2)}
          onCreate={handleCreate}
          onOpenTask={(id) => setOpenedTaskInLibrary(id)}
        />
      )}

      {successMessage && <div className={styles.successMessage}>{successMessage}</div>}

      <TaskDetailSheet
        taskId={openedTaskInLibrary}
        onClose={() => setOpenedTaskInLibrary(null)}
        onOpenTask={(id) => setOpenedTaskInLibrary(id)}
      />
    </div>
  );
}
