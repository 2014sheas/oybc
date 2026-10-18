import { RisoButton, RisoIcon, UndoStrip } from '../../riso';
import { StatusPill } from '../../StatusPill';

export interface NormalBodyProps {
  done: boolean;
  busy: boolean;
  /** Un-completing is blocked: the completion is held by a sealed window. */
  blocked: boolean;
  closedRow: React.ReactNode | null;
  onToggle: () => void;
  /** The Undo strip's line after a toggle made from here. */
  stripText?: string | null;
  onUndo?: () => void;
  /** Beside the button (Task Detail's Edit). */
  trailing?: React.ReactNode;
  /** The not-done pill's label (Task Detail: "NOT DONE THIS WEEK"). */
  notDoneLabel?: string;
}

/**
 * A Normal square's sheet body (reached from the hold menu's Details): its
 * status and a `Mark done` ↔ `Done` button.
 *
 * @returns The body.
 */
export function NormalBody({ done, busy, blocked, closedRow, onToggle, stripText, onUndo, trailing, notDoneLabel }: NormalBodyProps): React.ReactElement {
  return (
    <>
      <div>
        <StatusPill status={done ? 'completed' : 'notStarted'} labels={{ completed: 'DONE', inProgress: '', notStarted: notDoneLabel ?? 'NOT DONE' }} />
      </div>
      {closedRow ?? (
        <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
          <div style={{ flex: 1 }}>
            <RisoButton kind={done ? 'green' : 'gold'} fullWidth disabled={busy || (done && blocked)} icon={<RisoIcon name="check" size={16} aria-hidden="true" />} onClick={onToggle}>
              {done ? 'Done' : 'Mark done'}
            </RisoButton>
          </div>
          {trailing}
        </div>
      )}
      {stripText && onUndo && <UndoStrip text={stripText} onUndo={onUndo} disabled={busy} />}
    </>
  );
}
