import type { Task, Timeframe } from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { WizardQuickAddRow } from '../wizard/WizardQuickAddRow';
import { SpecialTaskPanel } from '../wizard/SpecialTaskPanel';
import styles from './SquarePickerSheet.module.css';

export type SquarePick = { taskId: string } | { pending: PendingTaskPayload };

export interface SquarePickerSheetProps {
  /** 'replace' shows the outgoing task's title; 'add' shows "Empty square" (D13, OQ4). */
  mode: 'replace' | 'add';
  /** Replace mode only — the outgoing square's current task title. */
  currentTaskTitle?: string;
  userId: string;
  timeframe?: Timeframe;
  startDate?: string;
  endDate?: string;
  /**
   * Eligible candidates for the quick-add row's inline library-match
   * dropdown — the caller has already filtered these via
   * `isSquarePickerCandidate` (excludes deleted tasks, tasks already in the
   * DRAFT — pending adds included — shared-counter family-mates, and
   * ineligible types).
   */
  libraryTasks: Task[];
  /** Fires once, covering every pick path: an existing library task, a
   *  staged (deferred) new normal/counting/achievement task, or an
   *  immediately-persisted compound. */
  onPick: (pick: SquarePick) => void;
  onClose: () => void;
}

/**
 * SquarePickerSheet — the squares editor's ONE add/replace surface (Board
 * Edit redesign slice 3, D13). Retires the play-mode "+" / `CellSwapModal`
 * picker (D17) and the edit-mode Replace picker — this is the only
 * remaining add/replace surface for both. Composes the wizard's quick-add
 * row (typed text → inline library matches, or Add creates a new NORMAL
 * task) with the collapsed special-task panel (counting / compound /
 * achievement) — no Library or Sources tab, per the handoff.
 */
export function SquarePickerSheet({
  mode,
  currentTaskTitle,
  userId,
  timeframe,
  startDate,
  endDate,
  libraryTasks,
  onPick,
  onClose,
}: SquarePickerSheetProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: onClose,
  });

  const kicker = mode === 'replace' ? 'Replace square' : 'Add square';
  const title = mode === 'replace' ? currentTaskTitle || '(untitled task)' : 'Empty square';

  return (
    <div className={styles.backdrop} onClick={onClose} role="presentation">
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label={`${kicker}: ${title}`}
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <div className={styles.headerText}>
            <span className={styles.kicker}>{kicker}</span>
            <h3 className={styles.title}>{title}</h3>
          </div>
          <button type="button" className={styles.closeButton} onClick={onClose} aria-label="Cancel">
            ✕
          </button>
        </div>

        <WizardQuickAddRow
          userId={userId}
          currentTimeframe={timeframe}
          currentStartDate={startDate}
          currentEndDate={endDate}
          libraryTasks={libraryTasks}
          onExistingTaskPicked={(task) => onPick({ taskId: task.id })}
          onTaskCreated={() => { /* no-op — onPendingCreated below carries the same payload */ }}
          onPendingCreated={(payload) => onPick({ pending: payload })}
        />

        <SpecialTaskPanel
          userId={userId}
          defaultTimeframe={timeframe}
          defaultStartDate={startDate}
          defaultEndDate={endDate}
          allowAchievement
          submitLabel="Add to board ✦"
          suggestionPool={libraryTasks}
          onTaskCreated={() => { /* no-op — onPendingCreated below carries the same payload */ }}
          onPendingCreated={(payload) => onPick({ pending: payload })}
          onCompoundCreated={(task) => onPick({ taskId: task.id })}
        />
      </div>
    </div>
  );
}
