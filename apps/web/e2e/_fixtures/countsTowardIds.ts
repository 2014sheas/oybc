/**
 * Fixed ids for `counts-toward-section.spec.ts` / `counts-toward-editor.spec.ts`.
 * The expected fork id is `forkTaskId(EDIT_BOARD, TWO_BOARD_TASK)` computed once
 * and hard-coded: e2e specs deliberately import nothing from `@oybc/shared` (the
 * CI e2e job never builds its `dist`). The value is pinned where importing
 * shared IS fine — `src/db/operations/__tests__/countsTowardIds.test.ts` fails
 * with a clear message if the uuid namespace or these seeds ever change.
 */
export const COUNTS_TOWARD_ROOT_ID = 'eeeeeeee-ctw0-0001-task-000000000001';
export const COUNTS_TOWARD_ROOT2_ID = 'eeeeeeee-ctw0-0001-task-000000000002';
export const COUNTS_TOWARD_EDIT_BOARD_ID = 'eeeeeeee-ctw0-0001-0000-000000000000';
export const COUNTS_TOWARD_OTHER_BOARD_ID = 'eeeeeeee-ctw0-0002-0000-000000000000';
export const COUNTS_TOWARD_TWO_BOARD_TASK_ID = 'eeeeeeee-ctw0-0001-task-000000000010';
export const COUNTS_TOWARD_EXPECTED_FORK_ID = '61ff50ba-81b6-5561-afa5-218544af8ae2';
