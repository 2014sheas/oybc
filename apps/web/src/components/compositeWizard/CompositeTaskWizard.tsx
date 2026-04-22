import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  OperatorType,
  TaskType,
  generateCounterTaskTitle,
  type CompositeTask,
} from '@oybc/shared';
import { db } from '../../db/database';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from '../playground/playgroundUtils';
import { type StepFormState, createEmptyStep } from '../progressStepUtils';
import {
  CompositeWizardStepper,
  type CompositeWizardStep,
} from './CompositeWizardStepper';
import { SetupStep } from './SetupStep';
import { BuildStep } from './BuildStep';
import { ReviewStep } from './ReviewStep';
import {
  type SubtaskDraft,
  type ExistingSubtaskDraft,
  type InlineSubtaskDraft,
} from './compositeSubtaskDraft';
import type { LibraryDiff } from './LibraryPickerSheet';
import styles from './CompositeTaskWizard.module.css';

export interface CompositeTaskWizardProps {
  /** User ID for task ownership. Defaults to playground user when omitted. */
  userId?: string;
  /** Invoked with the newly created CompositeTask after a successful save. */
  onCreated?: (compositeTask: CompositeTask) => void;
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
 * replaces the legacy CompositeTaskForm monolith. Owns the full draft
 * state, step transitions, and the atomic submit transaction. Step
 * content is delegated to SetupStep / BuildStep / ReviewStep.
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
  // Library feeds — live so a composite created elsewhere shows up here.
  const allTasks = useLiveQuery(
    () => db.tasks.where('[userId+isDeleted]').equals([resolvedUserId, 0]).toArray(),
    [resolvedUserId],
  ) ?? [];
  const allCompositeTasks = useLiveQuery(
    () => db.compositeTasks.where('[userId+isDeleted]').equals([resolvedUserId, 0]).toArray(),
    [resolvedUserId],
  ) ?? [];

  // Usage hints for the existing-task picker — "on N boards" for tasks
  // and "N subtasks" for composites. Queried here so the cards stay pure.
  const allBoardTasks = useLiveQuery(() => db.boardTasks.toArray(), []) ?? [];
  const allCompositeNodes = useLiveQuery(() => db.compositeNodes.toArray(), []) ?? [];
  const allTaskSteps = useLiveQuery(() => db.taskSteps.toArray(), []) ?? [];

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

  /** compositeTaskId → count of non-deleted leaf nodes (how many
   *  subtasks the composite has). */
  const compositeSubtaskCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const node of allCompositeNodes) {
      if (node.isDeleted) continue;
      if (node.nodeType !== 'leaf') continue;
      counts[node.compositeTaskId] = (counts[node.compositeTaskId] ?? 0) + 1;
    }
    return counts;
  }, [allCompositeNodes]);

  /** taskId → number of non-deleted steps (progress tasks only). */
  const taskStepCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const step of allTaskSteps) {
      if (step.isDeleted) continue;
      counts[step.taskId] = (counts[step.taskId] ?? 0) + 1;
    }
    return counts;
  }, [allTaskSteps]);

  /** compositeTaskId → first few leaf titles + total leaf count. Drives
   *  the "Run 5km, Meditate, +2 more" subtitle in the picker so users
   *  can preview a composite's contents without expanding it. */
  const compositeLeafPreviews = useMemo(() => {
    const previews: Record<string, { titles: string[]; totalLeaves: number }> = {};
    const taskTitleById = new Map<string, string>();
    for (const t of allTasks) taskTitleById.set(t.id, t.title);
    const compositeTitleById = new Map<string, string>();
    for (const ct of allCompositeTasks) compositeTitleById.set(ct.id, ct.title);

    // Group leaf nodes by composite; preserve nodeIndex ordering.
    const leavesByComposite = new Map<string, typeof allCompositeNodes>();
    for (const node of allCompositeNodes) {
      if (node.isDeleted) continue;
      if (node.nodeType !== 'leaf') continue;
      const arr = leavesByComposite.get(node.compositeTaskId) ?? [];
      arr.push(node);
      leavesByComposite.set(node.compositeTaskId, arr);
    }

    for (const [compositeId, leaves] of leavesByComposite) {
      leaves.sort((a, b) => a.nodeIndex - b.nodeIndex);
      const titles: string[] = [];
      for (const leaf of leaves.slice(0, 3)) {
        if (leaf.taskId) {
          const t = taskTitleById.get(leaf.taskId);
          if (t) titles.push(t);
        } else if (leaf.childCompositeTaskId) {
          const t = compositeTitleById.get(leaf.childCompositeTaskId);
          if (t) titles.push(t);
        }
      }
      previews[compositeId] = { titles, totalLeaves: leaves.length };
    }
    return previews;
  }, [allCompositeNodes, allTasks, allCompositeTasks]);

  // ─── State helpers ────────────────────────────────────────────────────────

  function addInlineSubtask(): void {
    setSubtasks((prev) => [...prev, createEmptyInlineSubtask()]);
  }

  /** Apply a LibraryPickerSheet commit: drop existing-mode drafts whose
   *  selectedId is in the remove set, then append fresh drafts for each
   *  new add. Inline drafts are untouched. Threshold clamping is handled
   *  by the effect below — this stays a pure state update. */
  function commitLibraryDiff(diff: LibraryDiff): void {
    setSubtasks((prev) => {
      const kept = prev.filter(
        (s) => !(s.mode === 'existing' && diff.remove.has(s.selectedId)),
      );
      const added = diff.add.map((a) => createExistingSubtask(a.id, a.kind));
      return [...kept, ...added];
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

  // ─── Submit ───────────────────────────────────────────────────────────────

  async function handleCreate(): Promise<void> {
    setErrorMessage(null);
    setIsSubmitting(true);
    try {
      const now = new Date().toISOString();
      const compositeTaskId = crypto.randomUUID();
      const rootNodeId = crypto.randomUUID();
      const resolvedLeaves: Array<{ taskId?: string; childCompositeTaskId?: string }> = [];

      await db.transaction(
        'rw',
        [db.tasks, db.taskSteps, db.compositeTasks, db.compositeNodes],
        async () => {
          for (const subtask of subtasks) {
            if (subtask.mode === 'existing') {
              if (subtask.selectionType === 'task') {
                resolvedLeaves.push({ taskId: subtask.selectedId });
              } else {
                resolvedLeaves.push({ childCompositeTaskId: subtask.selectedId });
              }
              continue;
            }

            const newTaskId = crypto.randomUUID();
            if (subtask.inlineType === 'normal') {
              await db.tasks.add({
                id: newTaskId,
                userId: resolvedUserId,
                title: subtask.title.trim(),
                type: TaskType.NORMAL,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
            } else if (subtask.inlineType === 'counting') {
              const maxCount = parseInt(subtask.maxCountStr, 10);
              const trimmedAction = subtask.action.trim();
              const trimmedUnit = subtask.unit.trim();
              const trimmedTitle = subtask.title.trim();
              // Use the shared counter-title helper so the blank-title
              // fallback stays in lock-step with the rest of the app if
              // the format ever changes.
              const resolvedTitle =
                trimmedTitle.length > 0
                  ? trimmedTitle
                  : generateCounterTaskTitle(trimmedAction, maxCount, trimmedUnit);
              await db.tasks.add({
                id: newTaskId,
                userId: resolvedUserId,
                title: resolvedTitle,
                type: TaskType.COUNTING,
                action: trimmedAction,
                unit: trimmedUnit,
                maxCount,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
            } else {
              // progress
              await db.tasks.add({
                id: newTaskId,
                userId: resolvedUserId,
                title: subtask.title.trim(),
                type: TaskType.PROGRESS,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
              for (let i = 0; i < subtask.steps.length; i++) {
                const step = subtask.steps[i];
                const stepType = step.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL;
                const trimmedStepTitle = step.title.trim();
                const trimmedAction = step.type === 'counting' ? step.action.trim() : '';
                const trimmedUnit = step.type === 'counting' ? step.unit.trim() : '';
                const stepMaxCount = step.type === 'counting' ? parseInt(step.maxCount, 10) : undefined;
                const resolvedStepTitle =
                  step.type === 'counting' && !trimmedStepTitle
                    ? generateCounterTaskTitle(trimmedAction, stepMaxCount!, trimmedUnit)
                    : trimmedStepTitle;
                const stepTaskId = crypto.randomUUID();
                await db.tasks.add({
                  id: stepTaskId,
                  userId: resolvedUserId,
                  title: resolvedStepTitle,
                  type: stepType,
                  action: step.type === 'counting' ? step.action.trim() || undefined : undefined,
                  unit: step.type === 'counting' ? step.unit.trim() || undefined : undefined,
                  maxCount: step.type === 'counting' ? parseInt(step.maxCount, 10) || undefined : undefined,
                  totalCompletions: 0,
                  totalInstances: 0,
                  createdAt: now,
                  updatedAt: now,
                  version: 1,
                  isDeleted: false,
                });
                await db.taskSteps.add({
                  id: crypto.randomUUID(),
                  taskId: newTaskId,
                  stepIndex: i,
                  title: resolvedStepTitle,
                  type: stepType,
                  action: step.type === 'counting' ? trimmedAction || undefined : undefined,
                  unit: step.type === 'counting' ? trimmedUnit || undefined : undefined,
                  maxCount: stepMaxCount,
                  linkedTaskId: stepTaskId,
                  createdAt: now,
                  updatedAt: now,
                  version: 1,
                  isDeleted: false,
                });
              }
            }

            resolvedLeaves.push({ taskId: newTaskId });
          }

          await db.compositeTasks.add({
            id: compositeTaskId,
            userId: resolvedUserId,
            title: title.trim(),
            description: undefined,
            rootNodeId,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
          });
          await db.compositeNodes.add({
            id: rootNodeId,
            compositeTaskId,
            parentNodeId: undefined,
            nodeIndex: 0,
            nodeType: 'operator',
            operatorType: operator,
            threshold: operator === OperatorType.M_OF_N ? threshold : undefined,
            taskId: undefined,
            childCompositeTaskId: undefined,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
          });
          for (let i = 0; i < resolvedLeaves.length; i++) {
            await db.compositeNodes.add({
              id: crypto.randomUUID(),
              compositeTaskId,
              parentNodeId: rootNodeId,
              nodeIndex: i,
              nodeType: 'leaf',
              operatorType: undefined,
              threshold: undefined,
              taskId: resolvedLeaves[i].taskId,
              childCompositeTaskId: resolvedLeaves[i].childCompositeTaskId,
              createdAt: now,
              updatedAt: now,
              version: 1,
              isDeleted: false,
            });
          }
        },
      );

      setSuccessMessage('Composite task created!');
      onCreated?.({
        id: compositeTaskId,
        userId: resolvedUserId,
        title: title.trim(),
        description: undefined,
        rootNodeId,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      });
      resetForm();
      setTimeout(() => setSuccessMessage(null), SUCCESS_DISMISS_MS);
    } catch (err) {
      setErrorMessage(`Failed: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsSubmitting(false);
    }
  }

  // ─── Render ───────────────────────────────────────────────────────────────

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
          allCompositeTasks={allCompositeTasks}
          taskBoardCounts={taskBoardCounts}
          taskStepCounts={taskStepCounts}
          compositeSubtaskCounts={compositeSubtaskCounts}
          compositeLeafPreviews={compositeLeafPreviews}
          onUpdateSubtask={updateSubtask}
          onRemoveSubtask={removeSubtask}
          onStepFieldChange={updateInlineStep}
          onAddStep={addStep}
          onRemoveStep={removeStep}
          onCommitLibraryDiff={commitLibraryDiff}
          onAddInline={addInlineSubtask}
          onBack={() => setCurrentStep(1)}
          onNext={() => setCurrentStep(3)}
        />
      )}

      {currentStep === 3 && (
        <ReviewStep
          title={title}
          operator={operator}
          threshold={threshold}
          subtasks={subtasks}
          allTasks={allTasks}
          allCompositeTasks={allCompositeTasks}
          isSubmitting={isSubmitting}
          errorMessage={errorMessage}
          onBack={() => setCurrentStep(2)}
          onCreate={handleCreate}
        />
      )}

      {successMessage && <div className={styles.successMessage}>{successMessage}</div>}
    </div>
  );
}
