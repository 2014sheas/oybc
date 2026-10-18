import * as fs from 'fs';
import * as path from 'path';
import {
  BoardSchema,
  BoardTaskSchema,
  CoreBoardDefaultSchema,
  RecurringBoardTemplateSchema,
  TaskEventSchema,
  TaskSchema,
  withNormalizedPlacementFields,
} from '../../src';

/**
 * Cross-platform pull-tolerance vectors (issue #300; docs/SYNC_STRATEGY.md
 * §Forward-compatible pull). The SAME fixture is run end-to-end through web's
 * `applyRemoteSubdoc` (`apps/web/.../pullToleranceVectors.test.ts`) and iOS's
 * `applyPullBatch` (`PullToleranceVectorTests.swift`); this suite pins the
 * schema layer both web paths build on. The iOS bundle copy is kept
 * byte-identical by `tests/fixtures/fixtureSync.test.ts`
 * (`pnpm --filter @oybc/shared run gen:sync-fixtures`).
 */

interface Vector {
  name: string;
  collection: string;
  set: Record<string, unknown>;
  disposition: 'applied' | 'quarantined';
  expect?: Record<string, unknown>;
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/pullToleranceVectors.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8')) as {
  bases: Record<string, Record<string, unknown>>;
  cases: Vector[];
};

const SCHEMAS: Record<string, { safeParse: (v: unknown) => { success: boolean; data?: unknown } }> = {
  boards: BoardSchema,
  tasks: TaskSchema,
  taskEvents: TaskEventSchema,
  boardTasks: {
    safeParse: (v) => {
      const r = BoardTaskSchema.safeParse(v);
      return r.success ? { success: true, data: withNormalizedPlacementFields(r.data) } : { success: false };
    },
  },
  recurringBoardTemplates: RecurringBoardTemplateSchema,
  coreBoardDefaults: CoreBoardDefaultSchema,
};

describe('pull tolerance vectors — schema layer', () => {
  it('has a base doc for every collection a case names', () => {
    for (const c of fixture.cases) expect(fixture.bases[c.collection]).toBeDefined();
  });

  it.each(fixture.cases.map((c) => [c.name, c] as const))('%s', (_name, vector) => {
    const doc = { ...JSON.parse(JSON.stringify(fixture.bases[vector.collection])), ...vector.set };
    doc.userId = doc.userId === '$USER' ? 'user-1' : doc.userId;
    const result = SCHEMAS[vector.collection].safeParse(doc);

    expect(result.success).toBe(vector.disposition === 'applied');
    if (vector.disposition === 'applied') {
      const parsed = result.data as Record<string, unknown>;
      for (const [field, want] of Object.entries(vector.expect ?? {})) {
        expect({ [field]: parsed[field] ?? null }).toEqual({ [field]: want });
      }
    }
  });
});
