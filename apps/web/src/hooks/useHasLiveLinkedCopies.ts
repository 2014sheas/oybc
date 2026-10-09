import { useLiveQuery } from 'dexie-react-hooks';
import { hasLiveLinkedCopies } from '../db/operations';

/**
 * Live: whether any non-deleted task links to `taskId` as its counter root
 * (`sharedCounterId == taskId`) — i.e. the task is a shared counter even when
 * it was born on a board. Feeds `typeLockedForEdit` in the task editors.
 * iOS twin: the sheets' on-open `hasLiveLinkedCopies(taskId:)` read.
 *
 * @param taskId - The task being edited.
 * @returns The answer, or `undefined` until the read resolves —
 *   `typeLockedForEdit` reads `undefined` as LOCKED, so the first frame never
 *   shows a picker that then disappears.
 */
export function useHasLiveLinkedCopies(taskId: string): boolean | undefined {
  return useLiveQuery(() => hasLiveLinkedCopies(taskId), [taskId]);
}
