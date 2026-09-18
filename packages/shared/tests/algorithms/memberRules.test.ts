/**
 * memberRules.test.ts — Board Sources §Member rules (B1).
 *
 * Vector-pinned suite for the pure member-rule helpers. Every expectation
 * lives in `tests/fixtures/memberRuleVectors.json` (hand-computed, never
 * generated from the code under test) so the Swift twin can assert the
 * identical numbers against the byte-identical iOS fixture copy.
 */
import fs from 'fs';
import path from 'path';
import { makeSeededRng } from '../../../bingo-core/tests/seededRng';
import { Timeframe, TaskType } from '../../src/constants/enums';
import {
  nominalWindowDays,
  autoTarget,
  varyRange,
  rollTarget,
  applyMemberRules,
  planDerivedTasks,
  derivedTaskId,
  derivedCompoundId,
  derivedLinkId,
  computeWindowBaseline,
  isWindowStampedDerived,
  buildDerivedRows,
} from '../../src/algorithms/memberRules';
import type { BaselineEvent } from '../../src/algorithms/memberRules';
import { TaskSchema, CompoundChildSchema } from '../../src/validation/schemas';
import type { VaryLevel, BoardSource, Task } from '../../src/types';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'memberRuleVectors.json'), 'utf8')
);

type ChildRow = { childTaskId: string; childIndex: number };

/**
 * Fixture `children` entries are either a bare childTaskId (childIndex = its
 * array position) or an explicit `{ childTaskId, childIndex }` pair — the
 * object form lets a vector put childIndex deliberately out of array order.
 */
const buildChildren = (raw: Record<string, unknown>): Record<string, ChildRow[]> =>
  Object.fromEntries(
    Object.entries(raw).map(([compoundId, kids]) => [
      compoundId,
      (kids as unknown[]).map((k, i) =>
        typeof k === 'string' ? { childTaskId: k, childIndex: i } : (k as ChildRow)
      ),
    ])
  );

const src = (i: number, kind: 'pool' | 'board', memberRules: BoardSource['memberRules']): BoardSource => ({
  sourceId: `s${i}`,
  kind,
  min: 0,
  max: null,
  excludedTaskIds: [],
  filter: 'all',
  ...(memberRules && Object.keys(memberRules).length ? { memberRules } : {}),
});

describe('nominalWindowDays', () => {
  it.each(V.windowDays as any[])('$name', (v: any) => {
    expect(nominalWindowDays(v.timeframe as Timeframe, v.startDate ?? null, v.endDate ?? null)).toBe(
      v.expected
    );
  });
});

describe('autoTarget', () => {
  it.each(V.autoTarget as any[])('$name', (v: any) => {
    expect(autoTarget(v.goal, v.sourceDays, v.targetDays)).toBe(v.expected);
  });
});

describe('varyRange', () => {
  it.each(V.varyRange as any[])('$name', (v: any) => {
    expect(varyRange(v.t, v.level as VaryLevel, v.goal)).toEqual(v.expected);
  });
});

describe('rollTarget', () => {
  it.each(V.rollTarget as any[])('$name', (v: any) => {
    const rng =
      v.seed === null
        ? () => {
            throw new Error('rng must not be called');
          }
        : makeSeededRng(v.seed);
    expect(rollTarget(v.t, v.level as VaryLevel, v.goal, rng)).toBe(v.expected);
  });
});

describe('applyMemberRules', () => {
  const F = V.applyMemberRules;
  const tasksById: Record<string, { id: string; type: TaskType }> = Object.fromEntries(
    Object.entries(F.tasks).map(([id, t]) => [id, { id, type: t as TaskType }])
  );
  const childrenByCompoundId = buildChildren(F.children);

  it.each(F.vectors as any[])('$name', (v: any) => {
    const out = applyMemberRules(
      [{ source: src(1, 'board', v.memberRules), supplyTaskIds: v.supply }],
      childrenByCompoundId,
      tasksById
    );
    expect(out).toHaveLength(1);
    expect(out[0].supplyTaskIds).toEqual(v.expected);
    expect(out[0].partOf).toEqual(v.expectedPartOf);
    expect(out[0].source.sourceId).toBe('s1');
  });
});

describe('planDerivedTasks', () => {
  const P = V.planDerivedTasks;
  const tasksById: Record<string, any> = Object.fromEntries(
    Object.entries(P.tasks).map(([id, t]: [string, any]) => [
      id,
      { id, ...t, sharedCounterId: t.sharedCounterId ?? null, startDate: t.startDate ?? undefined },
    ])
  );
  const childrenByCompoundId = buildChildren(P.children);
  const win = (tf: string) => ({ timeframe: tf as Timeframe, startDate: null, endDate: null });
  const sourceWindowByTaskId = Object.fromEntries(
    Object.entries(P.sourceWindows).map(([id, tf]) => [id, win(tf as string)])
  );
  const resolveId = (token: string): string =>
    token.startsWith('derived:') || token.startsWith('derivedCompound:') ? P.idPins[token] : token;

  it('pins the three id namespaces as literals', () => {
    expect(derivedTaskId(P.boardId, 'r1')).toBe(P.idPins['derived:r1']);
    expect(derivedTaskId(P.boardId, 'r2')).toBe(P.idPins['derived:r2']);
    expect(derivedTaskId(P.boardId, 'c1')).toBe(P.idPins['derived:c1']);
    expect(derivedTaskId(P.boardId, 'c3')).toBe(P.idPins['derived:c3']);
    expect(derivedTaskId(P.boardId, 'a1')).toBe(P.idPins['derived:a1']);
    expect(derivedCompoundId(P.boardId, 'C2')).toBe(P.idPins['derivedCompound:C2']);
    expect(derivedLinkId(P.idPins['derivedCompound:C2'], P.idPins['derived:c3'])).toBe(
      P.idPins['link:derivedCompound:C2:derived:c3']
    );
    expect(derivedLinkId(P.idPins['derivedCompound:C2'], P.idPins['derived:c1'])).toBe(
      P.idPins['link:derivedCompound:C2:derived:c1']
    );
    expect(derivedCompoundId(P.boardId, 'C')).toBe(P.idPins['derivedCompound:C']);
    expect(derivedLinkId(P.idPins['derivedCompound:C'], P.idPins['derived:c1'])).toBe(
      P.idPins['link:derivedCompound:C:derived:c1']
    );
    expect(derivedLinkId(P.idPins['derivedCompound:C'], 'c2')).toBe(
      P.idPins['link:derivedCompound:C:c2']
    );
    expect(P.idPins['derived:r1']).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    );
  });

  /** pinned id → its fixture token, so a link id can be looked up by token. */
  const tokenOfId: Record<string, string> = Object.fromEntries(
    Object.entries(P.idPins).map(([k, id]) => [id as string, k])
  );

  it.each(P.vectors as any[])('$name', (v: any) => {
    const supplies = v.supplies.map((s: any, i: number) => ({
      source: src(i + 1, s.kind, s.memberRules),
      supplyTaskIds: s.supply,
      partOf: s.partOf ?? {},
    }));
    const seeded = makeSeededRng(v.seed);
    let rngCalls = 0;
    const rng = () => {
      rngCalls += 1;
      return seeded();
    };
    const out = planDerivedTasks({
      selectedIds: v.selected,
      supplies,
      manualTaskIds: v.manual,
      manualTaskVary: v.manualTaskVary,
      boardId: P.boardId,
      window: P.window,
      mode: v.mode,
      tasksById,
      childrenByCompoundId,
      sourceWindowByTaskId,
      baselineByRootId: P.baselines,
      rng,
    });

    if (v.expectedRngCalls !== undefined) expect(rngCalls).toBe(v.expectedRngCalls);
    expect(out.placementIds).toEqual(v.expected.placement.map(resolveId));
    expect(
      out.derivedTasks.map((d) => ({
        root: d.rootTaskId,
        sourceMember: d.sourceMemberId,
        replaces: d.replacesId,
        maxCount: d.maxCount,
        baseline: d.baseline,
      }))
    ).toEqual(
      v.expected.derived.map((d: any) => ({
        root: d.root,
        sourceMember: d.sourceMember,
        replaces: d.replaces,
        maxCount: d.maxCount,
        baseline: d.baseline,
      }))
    );
    for (const d of out.derivedTasks) {
      expect(d.id).toBe(P.idPins[`derived:${d.rootTaskId}`]);
      expect(d.timeframe).toBe(P.window.timeframe);
      expect(d.startDate).toBe(P.window.startDate);
      expect(d.endDate).toBe(P.window.endDate);
    }
    for (const titled of v.expected.derived.filter((d: any) => d.title !== undefined)) {
      const d = out.derivedTasks.find((x) => x.rootTaskId === titled.root);
      expect(d).toBeDefined();
      expect([d!.title, d!.action, d!.unit]).toEqual([titled.title, titled.action, titled.unit]);
    }
    expect(
      out.derivedCompounds.map((c) => ({
        source: c.sourceCompoundId,
        replaces: c.replacesId,
        timeframe: c.timeframe,
        startDate: c.startDate,
        endDate: c.endDate,
        children: c.children.map((k) => ({
          child: k.childTaskId,
          childIndex: k.childIndex,
          isDerived: k.isDerived,
        })),
      }))
    ).toEqual(
      v.expected.compounds.map((c: any) => ({
        source: c.source,
        replaces: c.replaces,
        timeframe: c.timeframe,
        startDate: c.startDate,
        endDate: c.endDate,
        children: c.children.map((k: any) => ({ ...k, child: resolveId(k.child) })),
      }))
    );
    for (const c of out.derivedCompounds) {
      expect(c.id).toBe(P.idPins[`derivedCompound:${c.sourceCompoundId}`]);
      for (const k of c.children) {
        const childToken = tokenOfId[k.childTaskId] ?? k.childTaskId;
        expect(k.linkId).toBe(P.idPins[`link:derivedCompound:${c.sourceCompoundId}:${childToken}`]);
      }
    }
    for (const titledC of v.expected.compounds.filter((c: any) => c.title !== undefined)) {
      const c = out.derivedCompounds.find((x) => x.sourceCompoundId === titledC.source);
      expect(c).toBeDefined();
      expect([c!.title, c!.operator, c!.threshold]).toEqual([
        titledC.title,
        titledC.operator,
        titledC.threshold,
      ]);
    }
  });
});

// ─── B2: baseline + row building ─────────────────────────────────────────────

describe('computeWindowBaseline', () => {
  it.each(V.windowBaseline as any[])('$name', (v: any) => {
    expect(computeWindowBaseline(v.root, v.events as BaselineEvent[], v.boundary)).toBe(v.expected);
  });
});

describe('isWindowStampedDerived', () => {
  const full = {
    sharedCounterId: '11111111-0000-4000-8000-000000000001',
    startDate: '2026-09-18',
    createdInWizard: true,
  };

  it('all three marks then true', () => {
    expect(isWindowStampedDerived(full)).toBe(true);
  });

  it('no sharedCounterId then false (a plain window-scoped counting task)', () => {
    expect(isWindowStampedDerived({ ...full, sharedCounterId: null })).toBe(false);
  });

  it('no startDate then false (an ordinary linked counter, not window-stamped)', () => {
    expect(isWindowStampedDerived({ ...full, startDate: undefined })).toBe(false);
  });

  it('createdInWizard absent then false (a hand-made linked + timeboxed counter)', () => {
    expect(isWindowStampedDerived({ ...full, createdInWizard: undefined })).toBe(false);
  });
});

describe('buildDerivedRows', () => {
  const D = V.derivedRows;
  /** Fixture id token to its uuid; anything not a token passes through. */
  const id = (token: string): string => D.ids[token] ?? token;
  /** Recursively swap every id token inside a fixture value for its uuid. */
  const resolve = (value: any): any => {
    if (Array.isArray(value)) return value.map(resolve);
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolve(v)]));
    }
    return typeof value === 'string' ? id(value) : value;
  };

  const rootsById = Object.fromEntries(
    Object.entries(D.roots).map(([token, r]: [string, any]) => [id(token), { id: id(token), ...r }])
  );
  const compoundsById = Object.fromEntries(
    Object.entries(D.compounds).map(([token, c]: [string, any]) => [
      id(token),
      { ...c, id: id(token), threshold: c.threshold ?? undefined },
    ])
  );

  it('pins this section own derived + link ids as literals', () => {
    expect(derivedTaskId(D.boardId, id('R1'))).toBe(D.ids['derived:R1']);
    expect(derivedTaskId(D.boardId, id('R2'))).toBe(D.ids['derived:R2']);
    expect(derivedCompoundId(D.boardId, id('C'))).toBe(D.ids['derivedCompound:C']);
    expect(derivedLinkId(D.ids['derivedCompound:C'], D.ids['derived:R1'])).toBe(
      D.ids['link:derivedCompound:C:derived:R1']
    );
    expect(derivedLinkId(D.ids['derivedCompound:C'], id('K2'))).toBe(
      D.ids['link:derivedCompound:C:K2']
    );
  });

  it.each(D.vectors as any[])('$name', (v: any) => {
    const drafts = resolve(v.drafts);
    const expected = resolve(v.expected);
    const out = buildDerivedRows({
      drafts,
      userId: D.userId,
      now: D.now,
      rootsById,
      compoundsById,
    });

    // Order + length in full: derived counters in draft order, then compounds.
    expect(out.tasks.map((t) => t.id)).toEqual(expected.tasks.map((t: any) => t.id));
    expect(out.links.map((l) => l.id)).toEqual(expected.links.map((l: any) => l.id));

    out.tasks.forEach((row, i) => {
      const { expectedAbsent = [], ...fields } = expected.tasks[i];
      expect(row).toMatchObject(fields);
      for (const absent of expectedAbsent as string[]) {
        expect(row[absent as keyof Task]).toBeUndefined();
      }
      // Completeness: a forgotten required field fails here, not silently.
      const parsed = TaskSchema.safeParse(row);
      if (!parsed.success) {
        throw new Error(`TaskSchema rejected ${row.id}: ${JSON.stringify(parsed.error.issues)}`);
      }
      expect(parsed.success).toBe(true);
    });

    out.links.forEach((link, i) => {
      expect(link).toMatchObject(expected.links[i]);
      const parsed = CompoundChildSchema.safeParse(link);
      if (!parsed.success) {
        throw new Error(
          `CompoundChildSchema rejected ${link.id}: ${JSON.stringify(parsed.error.issues)}`
        );
      }
      expect(parsed.success).toBe(true);
    });

    // The derived counters keep the draft ids verbatim (the deterministic
    // uuidv5 minted by planDerivedTasks is the row id — never re-minted here).
    expect(out.tasks.slice(0, drafts.derivedTasks.length).map((t) => t.id)).toEqual(
      drafts.derivedTasks.map((d: any) => d.id)
    );
    for (const link of out.links) {
      const parent = out.tasks.find((t) => t.id === link.compoundTaskId);
      expect(parent?.type).toBe(TaskType.COMPOUND);
      expect([link.createdAt, link.updatedAt]).toEqual([D.now, D.now]);
    }
  });
});
