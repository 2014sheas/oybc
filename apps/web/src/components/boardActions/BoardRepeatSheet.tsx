import { useState } from 'react';
import type { Board, RecurringBoardTemplate, Task, WeekStartDay } from '@oybc/shared';
import { RisoButton } from '../riso';
import { useModalA11y } from '../../hooks/useModalA11y';
import { fetchBoard, BoardNotEditableError } from '../../db/operations/boards';
import { repeatBoardAsRecurring } from '../../db/operations/repeatBoard';
import { updateRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';
import {
  BoardEditRepeatSection,
  buildRepeatSavePlan,
  type RepeatCadenceChoice,
} from '../boardEdit/BoardEditRepeatSection';
import styles from './BoardDetailsSheet.module.css';

export interface BoardRepeatSheetProps {
  board: Board;
  /** Resolved source record; `undefined` for a one-off board. */
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  userId: string | undefined;
  weekStartDay: WeekStartDay;
  taskMap: Record<string, Task>;
  dealtTaskIds: string[];
  counterFamilyByTaskId: Record<string, string>;
  onClose: () => void;
  /** D11 — the save found the board sealed / deleted; the caller closes the
   *  sheet and shows the "Board closed" notice. */
  onBoardClosed: () => void;
  onSaved: () => void;
}

/**
 * BoardRepeatSheet — the "Repeat this board…" menu item's sheet (Board Edit
 * redesign slice 2, plan D6). Reuses the staged `BoardEditRepeatSection`
 * body unchanged (moved off the old panel); Save runs only what used to be
 * phase 2 of the panel's two-phase Save — there's no board write left to
 * pair it with here, so it collapses to one call.
 */
export function BoardRepeatSheet({
  board,
  sourceTemplate,
  userId,
  weekStartDay,
  taskMap,
  dealtTaskIds,
  counterFamilyByTaskId,
  onClose,
  onBoardClosed,
  onSaved,
}: BoardRepeatSheetProps): React.ReactElement {
  const [repeatCadence, setRepeatCadence] = useState<RepeatCadenceChoice>('off');
  const [repeatActiveDraft, setRepeatActiveDraft] = useState<boolean | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: () => !saving && onClose(),
  });

  const plan = buildRepeatSavePlan({
    spawnedFromTemplateId: board.spawnedFromTemplateId,
    sourceTemplateIsActive: sourceTemplate?.isActive,
    stagedCadence: repeatCadence,
    stagedActive: repeatActiveDraft,
    hasUserId: userId != null,
  });
  const canSave = plan != null && !saving;

  const handleSave = async (): Promise<void> => {
    if (!plan) return;
    setError(null);
    setSaving(true);
    try {
      if (plan.kind === 'startRepeating' && userId) {
        const freshBoard = (await fetchBoard(board.id)) ?? board;
        await repeatBoardAsRecurring(freshBoard, plan.cadence, userId, weekStartDay);
      } else if (plan.kind === 'setActive' && sourceTemplate) {
        await updateRecurringBoardTemplate(sourceTemplate.id, { isActive: plan.isActive });
      }
      onSaved();
    } catch (err) {
      if (err instanceof BoardNotEditableError) {
        onBoardClosed();
        return;
      }
      console.error('BoardRepeatSheet: save failed', err);
      setError('Save failed — please try again.');
      setSaving(false);
    }
  };

  return (
    <div className={styles.backdrop} onClick={() => !saving && onClose()} role="presentation">
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label="Repeat this board"
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <h2 className={styles.title}>Repeat this board</h2>
        </div>

        {error && (
          <p className={styles.error} role="alert">
            {error}
          </p>
        )}

        <BoardEditRepeatSection
          board={board}
          sourceTemplate={sourceTemplate}
          userId={userId}
          stagedCadence={repeatCadence}
          onStagedCadenceChange={setRepeatCadence}
          stagedActive={repeatActiveDraft ?? sourceTemplate?.isActive ?? true}
          onStagedActiveChange={setRepeatActiveDraft}
          taskMap={taskMap}
          dealtTaskIds={dealtTaskIds}
          counterFamilyByTaskId={counterFamilyByTaskId}
        />

        <div className={styles.footer}>
          <RisoButton kind="neutral" onClick={onClose} disabled={saving}>
            Cancel
          </RisoButton>
          <RisoButton kind="primary" disabled={!canSave} onClick={() => void handleSave()}>
            {saving ? 'Saving…' : 'Save'}
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
