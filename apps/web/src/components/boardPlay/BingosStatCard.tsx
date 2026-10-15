import { replayMomentKind, type Board, type MomentKind } from '@oybc/shared';
import play from '../play/Play.module.css';

export interface BingosStatCardProps {
  board: Pick<Board, 'status' | 'completedTasks' | 'totalTasks' | 'linesCompleted'>;
  /** Re-open the moment the board already earned (bingo or greenlog). */
  onReplay: (kind: MomentKind) => void;
}

/**
 * BingosStatCard — the play rail's gold "Bingos ★ N" card. Once the board has
 * earned a moment (`replayMomentKind`) the card is a button that replays it —
 * the Greenlog on a full board, else the Bingo — so its share sheet is never
 * lost behind "Back to board". With nothing earned it stays a plain card.
 */
export function BingosStatCard({ board, onReplay }: BingosStatCardProps): React.ReactElement {
  const kind = replayMomentKind(board);
  const { linesCompleted } = board;
  const body = (
    <>
      <div className={play.statK}>Bingos</div>
      <div className={play.statV}>
        <span className={play.starS} aria-hidden="true" />
        {linesCompleted}
      </div>
    </>
  );
  if (!kind) return <div className={`${play.stat} ${play.gold}`}>{body}</div>;
  return (
    <button
      type="button"
      className={`${play.stat} ${play.gold} ${play.statButton}`}
      onClick={() => onReplay(kind)}
      aria-label={`${linesCompleted} ${linesCompleted === 1 ? 'bingo' : 'bingos'} — replay the ${kind === 'greenlog' ? 'Greenlog' : 'Bingo'}`}
    >
      {body}
    </button>
  );
}
