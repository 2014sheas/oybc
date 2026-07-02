import { useNavigate } from 'react-router-dom';
import { RisoButton, RisoIcon, RisoBadge } from '../riso';
import styles from './DraftResumePrompt.module.css';

export interface DraftResumePromptProps {
  /** The draft board's id — used to build the `/create?resumeDraft=<id>` URL. */
  boardId: string;
  /** The draft board's name — shown as the section heading. */
  boardName: string;
}

/**
 * DraftResumePrompt — renders in place of a playable bingo grid when the
 * loaded board is still a DRAFT. Mirrors iOS `BoardPlayView.draftResumeSection`.
 *
 * Used as a catch-all safety net in `BoardPlayPage` (direct URL hits and any
 * secondary-nav paths that land on a draft's id) and inline inside
 * `CoreBoardWindowPage` (pager context, keeping the window bar visible).
 *
 * Primary surfaces (BoardsPage card taps, CoreStrip taps, CoreBoardBrowser
 * row taps) route to `/create?resumeDraft=<id>` before reaching either of
 * those containers, so this component is only visible on indirect paths.
 */
export function DraftResumePrompt({ boardId, boardName }: DraftResumePromptProps): React.ReactElement {
  const navigate = useNavigate();

  return (
    <div className={styles.prompt}>
      <div className={styles.header}>
        <h2 className={styles.name}>{boardName}</h2>
        <RisoBadge kind="draft">Draft</RisoBadge>
      </div>
      <p className={styles.heading}>This board is still a draft.</p>
      <p className={styles.body}>
        Finish setting it up in the wizard — drafts aren&apos;t playable until
        you complete them.
      </p>
      <RisoButton
        kind="primary"
        icon={<RisoIcon name="edit" size={16} />}
        onClick={() => navigate(`/create?resumeDraft=${boardId}`)}
      >
        Resume draft
      </RisoButton>
    </div>
  );
}
