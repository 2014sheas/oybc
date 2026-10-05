import { useCallback, useRef } from 'react';
import type { Pool, RecurringBoardTemplate, Task } from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton } from '../riso';
import { PoolEditorBody } from './PoolEditorBody';
import styles from './PoolEditorModal.module.css';

export interface PoolEditorModalProps {
  /** Authenticated user id — owner of the newly created pool. */
  userId: string;
  /** Active recurring-board templates (deck-preview floor input). */
  templates: RecurringBoardTemplate[];
  /** The user's full non-deleted task library. */
  allTasks: Task[];
  /** Draft-filtered subset of `allTasks` — the library picker's source. */
  browsableTasks: Task[];
  /** Pre-seeds `taskIds` (create mode). */
  initialTaskIds?: string[];
  /** Backdrop click / Escape / Cancel / Close. */
  onClose: () => void;
  /** Fired after a successful create, with the persisted `Pool` (the picker selects it). */
  onSaved: (pool: Pool) => void;
}

/**
 * PoolEditorModal — the modal shell around `PoolEditorBody` for the one
 * place a pool is built mid-flow: the pool picker's "+ Build a new pool…"
 * (inside the wizard's Sources sheet / the Core defaults sheet), where a
 * full-page navigation would abandon the surrounding sheet. Everywhere else
 * the editor is the full-screen `PoolEditorPage`. Create mode only.
 */
export function PoolEditorModal({
  userId,
  templates,
  allTasks,
  browsableTasks,
  initialTaskIds,
  onClose,
  onSaved,
}: PoolEditorModalProps): React.ReactElement {
  const busyRef = useRef(false);
  const onBusyChange = useCallback((busy: boolean) => {
    busyRef.current = busy;
  }, []);
  const dismiss = (): void => {
    if (!busyRef.current) onClose();
  };
  // aria-modal, Escape → close, initial focus, Tab trap, focus restore.
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: dismiss,
  });

  return (
    <div
      ref={modalRef}
      role="dialog"
      aria-labelledby="pool-edit-sheet-title"
      {...modalProps}
      className={styles.backdrop}
      onClick={dismiss}
    >
      <div className={styles.sheet} onClick={(e) => e.stopPropagation()}>
        <div className={styles.header}>
          <h3 id="pool-edit-sheet-title" className={styles.title}>
            New pool
          </h3>
          <RisoButton kind="neutral" size="small" onClick={dismiss}>
            Close
          </RisoButton>
        </div>
        <div className={styles.content}>
          <PoolEditorBody
            userId={userId}
            templates={templates}
            allTasks={allTasks}
            browsableTasks={browsableTasks}
            initialTaskIds={initialTaskIds}
            onCancel={onClose}
            onSaved={onSaved}
            onDeleted={onClose}
            onBusyChange={onBusyChange}
            stickyFooter
          />
        </div>
      </div>
    </div>
  );
}
