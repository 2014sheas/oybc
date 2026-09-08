import { useEffect } from 'react';
import type { RecurringBoardTemplate } from '@oybc/shared';
import styles from './MissingSourceDialog.module.css';

export interface MissingSourceDialogProps {
  /** The repeating board that can't make its next board, or `null` when
   *  the dialog is closed. */
  template: RecurringBoardTemplate | null;
  /** "Remove that source" — drop the dead board-kind source(s), then
   *  re-run the spawn pass. */
  onRemoveSource: (template: RecurringBoardTemplate) => void;
  /** "Pause this board" — set the repeating board inactive. */
  onPause: (template: RecurringBoardTemplate) => void;
  /** "Not now" — dismiss; re-asks on the next Boards-tab open. */
  onDismiss: () => void;
}

/**
 * MissingSourceDialog — the deleted-source ask (Board Sources P4 —
 * docs/BOARD_SOURCES.md §Boards as sources; iOS twin is
 * `BoardListView`'s `missingSourceAsk` alert). A repeating board pulling
 * from a deleted/archived board never spawns silently — the user decides
 * here. "Not now" re-asks on the next Boards-tab open (lazy, never
 * background).
 */
export function MissingSourceDialog({
  template,
  onRemoveSource,
  onPause,
  onDismiss,
}: MissingSourceDialogProps): React.ReactElement | null {
  useEffect(() => {
    if (template === null) return;
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') onDismiss();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [template, onDismiss]);

  if (template === null) return null;

  return (
    <div
      className={styles.backdrop}
      role="dialog"
      aria-modal="true"
      aria-labelledby="missing-source-title"
      onClick={onDismiss}
    >
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <h3 id="missing-source-title" className={styles.title}>
          &ldquo;{template.name}&rdquo; can&rsquo;t make its next board
        </h3>
        <p className={styles.body}>
          It pulls squares from a board that was deleted or archived.
        </p>
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.primaryButton}
            onClick={() => onRemoveSource(template)}
          >
            Remove that source
          </button>
          <button
            type="button"
            className={styles.neutralButton}
            onClick={() => onPause(template)}
          >
            Pause this board
          </button>
          <button type="button" className={styles.cancelButton} onClick={onDismiss}>
            Not now
          </button>
        </div>
      </div>
    </div>
  );
}
