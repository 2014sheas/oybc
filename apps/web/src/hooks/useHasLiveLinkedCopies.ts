import { useLiveQuery } from 'dexie-react-hooks';
import { hasLiveLinkedCopies } from '../db/operations';

/**
 * Live: whether any non-deleted task links to `taskId` as its counter root
 * (`sharedCounterId == taskId`) — i.e. the task is a shared counter even when
 * it was born on a board. Feeds `typeLockedForEdit` in the task editors.
 * iOS twin: the sheets' on-open `hasLiveLinkedCopies(taskId:)` read.
 *
 * @param taskId - The task being edited.
 * @returns True once the read resolves with a live copy; false meanwhile.
 */
export function useHasLiveLinkedCopies(taskId: string): boolean {
  return useLiveQuery(() => hasLiveLinkedCopies(taskId), [taskId]) ?? false;
}
