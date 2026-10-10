import { describe, expect, it } from 'vitest';
import { forkTaskId } from '@oybc/shared';
import {
  COUNTS_TOWARD_EDIT_BOARD_ID,
  COUNTS_TOWARD_EXPECTED_FORK_ID,
  COUNTS_TOWARD_TWO_BOARD_TASK_ID,
} from '../../../../e2e/_fixtures/countsTowardIds';

/**
 * Pins the hard-coded fork id `counts-toward-editor.spec.ts` asserts (e2e
 * specs import nothing from `@oybc/shared` — the CI e2e job never builds its
 * `dist`). If the fork-id namespace or the spec's seed ids change, this fails
 * here with a clear message instead of the e2e going red on CI.
 */
describe('counts-toward e2e fixture ids', () => {
  it('EXPECTED_FORK_ID is forkTaskId(EDIT_BOARD_ID, TWO_BOARD_TASK_ID)', () => {
    expect(forkTaskId(COUNTS_TOWARD_EDIT_BOARD_ID, COUNTS_TOWARD_TWO_BOARD_TASK_ID)).toBe(COUNTS_TOWARD_EXPECTED_FORK_ID);
  });
});
