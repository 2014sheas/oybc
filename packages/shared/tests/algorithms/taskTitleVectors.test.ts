import * as fs from 'fs';
import * as path from 'path';
import {
  counterCopyTitle,
  generateCounterTaskTitle,
  isAutoCounterTitle,
} from '../../src/algorithms/taskTitle';

const V = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'taskTitleVectors.json'), 'utf8')
);

/**
 * Cross-platform vector pins for `taskTitle.ts` ↔ iOS `TaskTitle.swift`
 * (`TaskTitleVectorTests`). The fixture is the single source of truth for
 * both suites; see its `_note` for the trim / case decisions.
 */

const orEmpty = (s: string | null | undefined): string => s ?? '';

describe('taskTitleVectors — generateCounterTaskTitle', () => {
  it.each(V.generateCounterTaskTitle as any[])('$name', (v: any) => {
    expect(
      generateCounterTaskTitle(v.action, v.maxCount ?? null, v.unit, v.providedTitle ?? undefined, v.countKind ?? undefined)
    ).toBe(v.expected);
  });
});

describe('taskTitleVectors — isAutoCounterTitle', () => {
  it('pins both outcomes', () => {
    const outcomes = new Set((V.isAutoCounterTitle as any[]).map((v) => v.expected));
    expect(outcomes).toEqual(new Set([true, false]));
  });

  it.each(V.isAutoCounterTitle as any[])('$name', (v: any) => {
    expect(isAutoCounterTitle(v.title, v.action, v.maxCount ?? null, v.unit, v.countKind ?? undefined)).toBe(v.expected);
  });
});

describe('taskTitleVectors — counterCopyTitle', () => {
  it.each(V.counterCopyTitle as any[])('$name', (v: any) => {
    expect(
      counterCopyTitle(
        {
          title: v.member.title,
          action: orEmpty(v.member.action) || undefined,
          unit: orEmpty(v.member.unit) || undefined,
          maxCount: v.member.maxCount ?? undefined,
        },
        v.newMaxCount
      )
    ).toBe(v.expected);
  });
});
