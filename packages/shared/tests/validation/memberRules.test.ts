import { BoardSourceSchema } from '../../src/validation/boardSource';
import { RecurringBoardTemplateSchema, CreateRecurringBoardTemplateInputSchema } from '../../src/validation/recurringBoardTemplate';

const base = { sourceId: '11111111-1111-4111-8111-111111111111', kind: 'board', min: 0, max: null, excludedTaskIds: [], filter: 'all' } as const;
const T = (n: number) => `22222222-2222-4222-8222-${String(n).padStart(12, '0')}`;

describe('BoardSource.memberRules (Zod)', () => {
  it('accepts a rule-less source unchanged (memberRules absent)', () => {
    const r = BoardSourceSchema.safeParse(base);
    expect(r.success).toBe(true);
    expect(r.success && 'memberRules' in r.data).toBe(false);
  });
  it('accepts a full rule set keyed by task id', () => {
    const r = BoardSourceSchema.safeParse({ ...base, memberRules: {
      [T(1)]: { target: 5, vary: 1 },
      [T(2)]: { split: true, parts: { [T(3)]: { target: 2 }, [T(4)]: { excluded: true }, [T(5)]: { vary: 2 } } },
      [T(6)]: { vary: 2 },
    }});
    expect(r.success).toBe(true);
  });
  it.each([
    ['target 0', { target: 0 }], ['target negative', { target: -1 }], ['target fractional', { target: 1.5 }],
    ['vary 3', { vary: 3 }], ['vary -1', { vary: -1 }], ['part target 0', { parts: { [T(3)]: { target: 0 } } }],
  ])('rejects %s', (_label, rule) => {
    expect(BoardSourceSchema.safeParse({ ...base, memberRules: { [T(1)]: rule } }).success).toBe(false);
  });
});

describe('RecurringBoardTemplate.manualTaskVary (Zod)', () => {
  const tmpl = { id: T(9), userId: T(8), name: 'x', timeframe: 'weekly', boardSize: 3, centerSquareType: 'none', isRandomized: true,
    seedTaskIds: [], isActive: true, lastSpawnedWindowKey: null, createdAt: '2026-09-18T00:00:00.000Z', updatedAt: '2026-09-18T00:00:00.000Z', version: 1, isDeleted: false };
  it('is optional and validates levels', () => {
    expect(RecurringBoardTemplateSchema.safeParse(tmpl).success).toBe(true);
    expect(RecurringBoardTemplateSchema.safeParse({ ...tmpl, manualTaskVary: { [T(1)]: 2, [T(2)]: 0 } }).success).toBe(true);
    expect(RecurringBoardTemplateSchema.safeParse({ ...tmpl, manualTaskVary: { [T(1)]: 5 } }).success).toBe(false);
    expect(CreateRecurringBoardTemplateInputSchema.safeParse({ name: 'x', timeframe: 'weekly', boardSize: 3, centerSquareType: 'none', isRandomized: true, seedTaskIds: [T(7)], isActive: true, manualTaskVary: { [T(1)]: 1 } }).success).toBe(true);
  });
});

describe('worst-case template size — payload-regression guard', () => {
  it('worst-case template stays under the 64 KiB payload regression guard', () => {
    const sources = Array.from({ length: 20 }, (_, s) => ({ ...base, sourceId: T(100 + s), min: 1, max: 5,
      memberRules: Object.fromEntries(Array.from({ length: 8 }, (_, m) => [T(1000 + s * 10 + m), {
        target: 12, vary: 1, split: true, parts: { [T(1)]: { target: 3, vary: 2 }, [T(2)]: { excluded: true }, [T(3)]: { vary: 1 } } }])) }));
    const bytes = Buffer.byteLength(JSON.stringify({ sources }), 'utf8');
    expect(bytes).toBeGreaterThan(9000);   // guard that the fixture is actually worst-case-ish
    // Measured worst case (20 sources × 8 members × 3 parts): 43 193 bytes —
    // well over the 10 000 the spec originally guessed at.
    //
    // This bound is a PAYLOAD-REGRESSION GUARD ONLY: it says "the worst-case
    // record has not grown past 64 KiB since it was measured", and nothing
    // about any Firestore limit. It is NOT the `firestore.rules` cap —
    // security rules expose no byte-size API to assert against (`.size()` on
    // a map is a KEY count), so what that clause actually measures, and the
    // real per-document ceiling, are settled by a B2 emulator test that
    // writes a worst-case record, not by this file.
    expect(bytes).toBeLessThan(65536);
  });
});
