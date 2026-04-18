import type { Board } from '@oybc/shared';
import { useDraftTaskCount } from '../../pages/createHub/useDrafts';
import styles from './CreateHubDraftsList.module.css';

export interface CreateHubDraftsListProps {
  drafts: Board[];
  /** Called with the tapped draft's Board record. Parent is
   *  responsible for loading its `BoardTask` rows and mounting the
   *  wizard with the full draft payload. */
  onResume: (draft: Board) => void;
}

/**
 * CreateHubDraftsList — Lists the user's existing DRAFT boards so
 * they can be resumed from where they left off. Rendered
 * conditionally (the Create Hub only mounts this when
 * `drafts.length > 0`) and shows each draft as a tap-to-resume row
 * with name, size, and a live task count.
 */
export function CreateHubDraftsList({
  drafts,
  onResume,
}: CreateHubDraftsListProps): React.ReactElement {
  return (
    <section className={styles.section} aria-label="Drafts">
      <h3 className={styles.heading}>
        Drafts
        <span className={styles.count}>{drafts.length}</span>
      </h3>
      <ul className={styles.list}>
        {drafts.map((draft) => (
          <DraftRow key={draft.id} draft={draft} onResume={onResume} />
        ))}
      </ul>
    </section>
  );
}

interface DraftRowProps {
  draft: Board;
  onResume: (draft: Board) => void;
}

function DraftRow({ draft, onResume }: DraftRowProps): React.ReactElement {
  const taskCount = useDraftTaskCount(draft.id);
  return (
    <li>
      <button
        type="button"
        className={styles.row}
        onClick={() => onResume(draft)}
        aria-label={`Resume "${draft.name}", ${draft.boardSize}×${draft.boardSize} board with ${taskCount} tasks`}
      >
        <div className={styles.rowInfo}>
          <span className={styles.rowName}>{draft.name || '(untitled draft)'}</span>
          <span className={styles.rowMeta}>
            {draft.boardSize}×{draft.boardSize} · {taskCount} task
            {taskCount === 1 ? '' : 's'}
          </span>
        </div>
        <span className={styles.rowChevron} aria-hidden="true">
          ›
        </span>
      </button>
    </li>
  );
}
