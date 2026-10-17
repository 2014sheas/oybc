import { RisoButton, RisoIcon } from '../../riso';
import { StatusPill } from '../../StatusPill';

export interface NormalBodyProps {
  done: boolean;
  busy: boolean;
  /** Un-completing is blocked: the completion is held by a sealed window. */
  blocked: boolean;
  closedRow: React.ReactNode | null;
  onToggle: () => void;
}

/**
 * A Normal square's sheet body (reached from the hold menu's Details): its
 * status and a `Mark done` ↔ `Done` button.
 *
 * @returns The body.
 */
export function NormalBody({ done, busy, blocked, closedRow, onToggle }: NormalBodyProps): React.ReactElement {
  return (
    <>
      <div>
        <StatusPill status={done ? 'completed' : 'notStarted'} labels={{ completed: 'DONE', inProgress: '', notStarted: 'NOT DONE' }} />
      </div>
      {closedRow ?? (
        <RisoButton kind={done ? 'green' : 'gold'} fullWidth disabled={busy || (done && blocked)} icon={<RisoIcon name="check" size={16} aria-hidden="true" />} onClick={onToggle}>
          {done ? 'Done' : 'Mark done'}
        </RisoButton>
      )}
    </>
  );
}
