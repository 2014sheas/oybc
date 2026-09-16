import { describe, expect, it } from 'vitest';
import { recurringBadgeState } from '../recurringBadgeState';

/**
 * Late-mutation audit, finding 3 — the badge used to render "RECURRING"
 * (un-paused, card un-dimmed) while templates were unresolved, then flip
 * to "↻ PAUSED". The first attempt at this fix only changed the `paused`
 * expression, which still evaluated false during load — a no-op the
 * review caught. These assert the RENDERED STATE, which is what flips.
 */
describe('recurringBadgeState', () => {
  const spawned = { spawnedFromTemplateId: 'tpl-1' };
  const oneOff = { spawnedFromTemplateId: undefined };

  it('is hidden while templates are unresolved — never a claim it may reverse', () => {
    expect(recurringBadgeState(spawned, undefined, false)).toBe('hidden');
  });

  it('a paused board goes hidden → paused, NEVER recurring → paused', () => {
    const loading = recurringBadgeState(spawned, undefined, false);
    const loaded = recurringBadgeState(spawned, { isActive: false }, true);
    expect(loading).toBe('hidden');
    expect(loaded).toBe('paused');
    expect(loading).not.toBe('recurring');
  });

  it('an active repeating board reads recurring once resolved', () => {
    expect(recurringBadgeState(spawned, { isActive: true }, true)).toBe('recurring');
  });

  it('a resolved-but-missing template still reads recurring (board says it was spawned)', () => {
    expect(recurringBadgeState(spawned, undefined, true)).toBe('recurring');
  });

  it('a one-off board is always hidden', () => {
    expect(recurringBadgeState(oneOff, undefined, false)).toBe('hidden');
    expect(recurringBadgeState(oneOff, { isActive: false }, true)).toBe('hidden');
  });
});
