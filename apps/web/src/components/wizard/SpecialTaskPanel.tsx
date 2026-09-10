import { useEffect, useState } from 'react';
import { TaskType, type Task, type Timeframe } from '@oybc/shared';
import { useCreateFormState, type PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { CreateNewTaskForm } from '../../pages/createPage/CreateNewTaskForm';
import { useLinkedCounterCreate } from './useLinkedCounterCreate';
import { RisoSectionLabel } from '../riso';
import styles from './SpecialTaskPanel.module.css';

/** Normal is deliberately excluded — the step's separate quick-add row
 *  already covers it (mirrors iOS `RisoSpecialTaskPanel.SpecialType`). */
const SPECIAL_TYPES: TaskType[] = [TaskType.COUNTING, TaskType.COMPOUND, TaskType.ACHIEVEMENT];
/** Pool-context types — achievements are banned from pools (owner
 *  decision 2026-09-10; see `isSourceSupplyTask` in @oybc/shared). */
const POOLABLE_TYPES: TaskType[] = [TaskType.COUNTING, TaskType.COMPOUND];

export interface SpecialTaskPanelProps {
  userId: string;
  defaultTimeframe?: Timeframe;
  defaultStartDate?: string;
  defaultEndDate?: string;
  /** False in pool context (`PoolEditSheet`): drops the Achievement type
   *  option and shortens the collapsed label to match. Default true (the
   *  wizard Tasks step — boards hand-place achievements). */
  allowAchievement?: boolean;
  /** Submit-button copy — defaults to the wizard's "Add to board ✦";
   *  pool context passes "Add to pool ✦". */
  submitLabel?: string;
  /** Fired when a COUNTING/ACHIEVEMENT task is created — the wizard
   *  auto-adds the new id to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /** Bug #85 — deferred-persist supplemental callback. Presence implies
   *  deferred mode (same convention as `NewTaskSheet`). */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /** Fired when a compound task is created (always immediate-persist —
   *  `CompoundTaskWizard` doesn't support deferred creation). */
  onCompoundCreated: (task: Task) => void;
  /**
   * R1 counters refresh (review fix) — unfiltered task pool (persisted +
   * this wizard session's pending tasks) used for the counter-link
   * auto-link match. See `CreateNewTaskForm`'s `suggestionPool` doc.
   */
  suggestionPool?: Task[];
}

/**
 * SpecialTaskPanel — collapsible "counting, compound or achievement" entry
 * point for the wizard Tasks step (Web inline-editing port PR-1, porting
 * iOS `RisoSpecialTaskPanel`).
 *
 * Collapsed: a dashed "+ Add a counting, compound or achievement task"
 * button (handoff §2, `RisoLibrarySheetView.entryButton` sibling). Expanded:
 * a "SPECIAL TASK" card with a Type selector restricted to Counting /
 * Compound / Achievement, reusing `CreateNewTaskForm` VERBATIM via its new
 * `typeOptions` prop rather than re-implementing per-type validation /
 * creation — see CLAUDE.md "reuse before creating". Compound selection
 * swaps to the existing `CompoundTaskWizard` (immediate-persist, via
 * `CreateNewTaskForm`), exactly as the modal `NewTaskSheet` does.
 *
 * This IS a presentation simplification versus the handoff's bespoke
 * per-type field layout (Verb/Goal/Counting on one row, rule chips, "Watch
 * a…" chips): reusing the existing form/hook wholesale was the explicit
 * PR-1 guardrail ("don't reinvent the creation — reuse it, just present it
 * in the panel"). `CreateNewTaskForm` is already Riso-token-styled, so the
 * result stays visually consistent even though the field arrangement
 * differs from the mockup.
 */
export function SpecialTaskPanel(props: SpecialTaskPanelProps): React.ReactElement {
  const [isExpanded, setIsExpanded] = useState(false);
  const allowAchievement = props.allowAchievement ?? true;

  if (!isExpanded) {
    return (
      <button
        type="button"
        className={styles.collapsedButton}
        onClick={() => setIsExpanded(true)}
      >
        <span className={styles.collapsedPlus} aria-hidden="true">＋</span>
        <span className={styles.collapsedLabel}>
          {allowAchievement
            ? 'Add a counting, compound or achievement task'
            : 'Add a counting or compound task'}
        </span>
      </button>
    );
  }

  // Mounted only while expanded — mirrors `NewTaskSheet`'s
  // `NewTaskSheetBody` pattern so `useCreateFormState` resets cleanly
  // every time the panel re-opens instead of leaking a half-typed draft.
  return <ExpandedPanel {...props} onCollapse={() => setIsExpanded(false)} />;
}

function ExpandedPanel({
  userId,
  defaultTimeframe,
  defaultStartDate,
  defaultEndDate,
  allowAchievement = true,
  submitLabel = 'Add to board ✦',
  onTaskCreated,
  onPendingCreated,
  onCompoundCreated,
  suggestionPool,
  onCollapse,
}: SpecialTaskPanelProps & { onCollapse: () => void }): React.ReactElement {
  const form = useCreateFormState({
    userId,
    onTaskCreated: (task) => {
      onTaskCreated(task);
      onCollapse();
    },
    onPendingCreated,
    defaultTimeframe,
    defaultStartDate,
    defaultEndDate,
    deferPersist: onPendingCreated !== undefined,
  });

  // The hook's own default is NORMAL (the Tasks-tab/`NewTaskSheet`
  // baseline) — this panel never offers Normal, so force Counting as the
  // opening type on every fresh mount (mirrors iOS's
  // `@State private var selectedType: SpecialType = .counting`).
  useEffect(() => {
    form.handleTypeChange(TaskType.COUNTING);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- run once on mount only
  }, []);

  const handleCreateLinked = useLinkedCounterCreate({
    userId,
    defaultTimeframe,
    defaultStartDate,
    defaultEndDate,
    onTaskCreated,
    onPendingCreated,
    onCreated: onCollapse,
  });

  return (
    <div className={styles.expandedCard}>
      <div className={styles.header}>
        <RisoSectionLabel>Special task</RisoSectionLabel>
        <button
          type="button"
          className={styles.dismissButton}
          onClick={onCollapse}
          aria-label="Close special task panel"
        >
          ✕
        </button>
      </div>

      <CreateNewTaskForm
        form={form}
        userId={userId}
        onCompositeCreated={(ct) => {
          onCompoundCreated(ct);
          onCollapse();
        }}
        submitLabel={submitLabel}
        onCreateLinked={handleCreateLinked}
        suggestionPool={suggestionPool}
        typeOptions={allowAchievement ? SPECIAL_TYPES : POOLABLE_TYPES}
      />
    </div>
  );
}
