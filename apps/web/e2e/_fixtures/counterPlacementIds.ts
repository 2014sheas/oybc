/**
 * Fixed ids for `counter-placement-defaults.spec.ts`. The expected copy id is
 * `derivedTaskId(BOARD_ID, GOALLESS_ROOT_ID)` computed once and hard-coded:
 * e2e specs deliberately import nothing from `@oybc/shared` (the CI e2e job
 * never builds its `dist`). The value is pinned where importing shared IS
 * fine — `src/db/operations/__tests__/counterPlacementIds.test.ts` fails with
 * a clear message if the uuid namespace or these seeds ever change.
 */
export const COUNTER_PLACEMENT_BOARD_ID = 'dddddddd-cpd0-0001-0000-000000000000';
export const COUNTER_PLACEMENT_GOALLESS_ROOT_ID = 'dddddddd-cpd0-0001-task-000000000003';
export const COUNTER_PLACEMENT_EXPECTED_COPY_ID = '74bb0ff9-be31-5328-ad7d-731dbdfd24e5';
