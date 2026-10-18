import { useEffect, useRef, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { useLocation, useNavigate } from 'react-router-dom';
import type { Task } from '@oybc/shared';
import { fetchTask } from '../db/operations';
import { useModalA11y } from '../hooks/useModalA11y';
import { TaskDetailContent } from '../pages/tasks/TaskDetailContent';
import type { DetailSegment } from '../pages/tasks/taskDetail/taskDetailModel';
import type { RisoTaskType } from './riso';
import styles from './TaskDetailSheet.module.css';

interface TaskDetailSheetProps {
  /** Task ID to display. When null, the sheet renders nothing (closed state). */
  taskId: string | null;
  /** Called when the user dismisses the sheet (Done pill, backdrop tap, or Escape). */
  onClose: () => void;
  /**
   * The board the sheet was opened from: tapping that board's row just
   * dismisses; any other board closes the sheet and navigates to it.
   */
  fromBoardId?: string;
}

/**
 * TaskDetailSheet — "Open in library": the SAME `TaskDetailContent` the route
 * renders, presented as a fixed-overlay sheet (grabber, Done pill grouped with
 * ⋯, no back chevron). In-sheet navigation pushes onto a stack; once swapped, a
 * return pill (type letter + previous name) takes the chevron slot and pops.
 * The selected segment survives swaps.
 *
 * @returns The sheet, or null when `taskId` is null.
 */
export function TaskDetailSheet({ taskId, onClose, fromBoardId }: TaskDetailSheetProps): React.ReactElement | null {
  if (taskId === null) return null;
  // Keyed by the opening task: a fresh open starts a fresh stack + segment.
  return <SheetBody key={taskId} rootTaskId={taskId} onClose={onClose} fromBoardId={fromBoardId} />;
}

function SheetBody({ rootTaskId, onClose, fromBoardId }: { rootTaskId: string; onClose: () => void; fromBoardId?: string }): React.ReactElement {
  const [stack, setStack] = useState<string[]>([rootTaskId]);
  const [segment, setSegment] = useState<DetailSegment>('all');
  const currentId = stack[stack.length - 1];
  const previousId = stack.length > 1 ? stack[stack.length - 2] : null;

  // Auto-dismiss when the user navigates anywhere outside the sheet. In-sheet
  // swaps don't change the URL, so they don't trigger this.
  const location = useLocation();
  const navigate = useNavigate();
  const initialPath = useRef(location.pathname);
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({ open: true, onCancel: onClose });
  useEffect(() => {
    if (location.pathname !== initialPath.current) onClose();
  }, [location.pathname, onClose]);

  // Live: an edit refreshes the page; a delete (or a missing id) shows the empty state.
  const task = useLiveQuery<Task | null>(async () => (await fetchTask(currentId)) ?? null, [currentId]);
  const previous = useLiveQuery<Task | null>(async () => (previousId ? (await fetchTask(previousId)) ?? null : null), [previousId]);
  const missing = task === null || (task !== undefined && task.isDeleted);

  const leave = (path: string): void => { onClose(); navigate(path); };

  return (
    <div className={styles.backdrop} onClick={onClose} role="presentation">
      <div ref={modalRef} className={styles.sheetPanel} role="dialog" aria-label="Task detail" {...modalProps} onClick={(e) => e.stopPropagation()}>
        {task === undefined && <p className={styles.statusMessage}>Loading…</p>}

        {missing && (
          <div className={styles.missingState}>
            <p className={styles.statusMessage}>This task no longer exists.</p>
            <button type="button" className={styles.doneButton} onClick={onClose}>Close</button>
          </div>
        )}

        {task && !task.isDeleted && (
          <TaskDetailContent
            key={task.id}
            task={task}
            onChanged={() => {}}
            onDeleted={onClose}
            chrome={{
              kind: 'sheet',
              onDone: onClose,
              returnTo: previous && !previous.isDeleted
                ? { title: previous.title || '(untitled task)', type: previous.type as RisoTaskType, onReturn: () => setStack((s) => s.slice(0, -1)) }
                : undefined,
            }}
            segment={segment}
            onSegment={setSegment}
            onOpenTask={(id) => setStack((s) => [...s, id])}
            onOpenBoard={(id) => (id === fromBoardId ? onClose() : leave(`/boards/${id}`))}
            onOpenCounter={(id) => leave(`/profile/counters/${id}`)}
          />
        )}
      </div>
    </div>
  );
}
