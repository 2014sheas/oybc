import { describe, expect, it } from 'vitest';
import { derivedTaskId } from '@oybc/shared';
import {
  COUNTER_PLACEMENT_BOARD_ID,
  COUNTER_PLACEMENT_EXPECTED_COPY_ID,
  COUNTER_PLACEMENT_GOALLESS_ROOT_ID,
} from '../../../../e2e/_fixtures/counterPlacementIds';

/**
 * Pins the hard-coded copy id `counter-placement-defaults.spec.ts` asserts
 * (e2e specs import nothing from `@oybc/shared` — the CI e2e job never builds
 * its `dist`). If the derived-id namespace or the spec's seed ids change, this
 * fails here with a clear message instead of the e2e going red on CI.
 */
describe('counter-placement-defaults e2e fixture ids', () => {
  it('EXPECTED_COPY_ID is derivedTaskId(BOARD_ID, GOALLESS_ROOT_ID)', () => {
    expect(derivedTaskId(COUNTER_PLACEMENT_BOARD_ID, COUNTER_PLACEMENT_GOALLESS_ROOT_ID)).toBe(
      COUNTER_PLACEMENT_EXPECTED_COPY_ID,
    );
  });
});
