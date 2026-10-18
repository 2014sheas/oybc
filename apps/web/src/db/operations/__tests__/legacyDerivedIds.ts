import { uuidv5 } from '@oybc/shared';

/**
 * The id a pre-rework build gave the per-window derived counter for `rootId`
 * on `boardId` (retired with the migration sweep in TASK_WINDOW_REWORK slice
 * 5). Tests use it to seed a legacy row or to assert that no such row is
 * minted any more.
 *
 * @param boardId - The board the row would have been minted for.
 * @param rootId - The shared-counter root.
 * @returns The legacy deterministic uuidv5.
 */
export function legacyDerivedTaskId(boardId: string, rootId: string): string {
  return uuidv5(`sources:derived:${boardId}:${rootId}`);
}
