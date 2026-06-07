import type { Board } from '@oybc/shared';
import { useDraftTaskCount } from '../../pages/createHub/useDrafts';
import styles from './CreateHubDraftsList.module.css';

export interface CreateHubDraftsListProps {
  drafts: Board[];
  /** Called with the tapped draft's Board record. Parent is
   *  responsible for loading its `BoardTask` rows and mounting the
   *  wizard with the full draft payload. */
  onResume: (draft: Board) => void;
  /** Called when the user confirms the per-row delete affordance.
   *  Parent runs `deleteDraftWithCascade(draft.id)` and the reactive
   *  drafts query removes the row on next render. */
  onDelete: (draft: Board) => void;
}

/**
 * CreateHubDraftsList — Lists the user's existing DRAFT boards so
 * they can be resumed from where they left off. Rendered
 * conditionally (the Create Hub only mounts this when
 * `drafts.length > 0`) and shows each draft as a tap-to-resume row
 * with name, size, a live task count, and a × delete button on the
 * right.
 */
export function CreateHubDraftsList({
  drafts,
  onResume,
  onDelete,
}: CreateHubDraftsListProps): React.ReactElement {
  return (
    <section className={styles.section} aria-label="Drafts">
      <h3 className={styles.heading}>
        Drafts
        <span className={styles.count}>{drafts.length}</span>
      </h3>
      <ul className={styles.list}>
        {drafts.map((draft) => (
          <DraftRow key={draft.id} draft={draft} onResume={onResume} onDelete={onDelete} />
        ))}
      </ul>
    </section>
  );
}

interface DraftRowProps {
  draft: Board;
  onResume: (draft: Board) => void;
  onDelete: (draft: Board) => void;
}

function DraftRow({ draft, onResume, onDelete }: DraftRowProps): React.ReactElement {
  const taskCount = useDraftTaskCount(draft.id);
  const displayName = draft.name || '(untitled draft)';

  function handleDelete(): void {
    const ok = window.confirm(
      `Delete draft "${displayName}"? Its ${taskCount} placed task${taskCount === 1 ? '' : 's'} ` +
        `will be removed from the board. The underlying tasks stay in your library.`,
    );
    if (ok) onDelete(draft);
  }

  return (
    <li className={styles.row}>
      <button
        type="button"
        className={styles.rowResume}
        onClick={() => onResume(draft)}
        aria-label={`Resume "${displayName}", ${draft.boardSize}×${draft.boardSize} board with ${taskCount} tasks`}
      >
        <div className={styles.rowInfo}>
          <span className={styles.rowName}>{displayName}</span>
          <span className={styles.rowMeta}>
            {draft.boardSize}×{draft.boardSize} · {taskCount} task
            {taskCount === 1 ? '' : 's'}
          </span>
        </div>
        <span className={styles.rowChevron} aria-hidden="true">
          ›
        </span>
      </button>
      <button
        type="button"
        className={styles.rowDelete}
        onClick={handleDelete}
        aria-label={`Delete draft "${displayName}"`}
        title="Delete draft"
      >
        ×
      </button>
    </li>
  );
}
