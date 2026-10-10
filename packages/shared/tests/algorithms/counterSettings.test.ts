import * as fs from 'fs';
import * as path from 'path';
import {
  changedCounterSettingsKeys,
  counterDisplayName,
  counterSettingsDefaults,
  counterSettingsDraftFromRoot,
  defaultTitleTemplates,
  derivedTimeframeGoals,
  effectiveTitleTemplates,
  formatTitleCount,
  renderCounterTitle,
  resolveCounterDefaultGoal,
  storedCounterSettings,
  storedCounterSettingsFromDraft,
} from '../../src/algorithms/counterSettings';
import { counterCopyTitle, generateCounterTaskTitle, isAutoCounterTitle } from '../../src/algorithms/taskTitle';

const read = (name: string): any =>
  JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', name), 'utf8'));
const V = read('counterSettingsVectors.json');
const TITLE_V = read('taskTitleVectors.json');

/**
 * Vector pins for `counterSettings.ts` ↔ iOS `CounterSettings.swift`
 * (`CounterSettingsVectorTests`) — docs/SHARED_COUNTER_SETTINGS.md §1.
 */

describe('counterSettingsVectors — defaultTitleTemplates', () => {
  it.each(V.defaultTitleTemplates as any[])('$name', (v: any) => {
    expect(defaultTitleTemplates(v.root)).toEqual(v.expected);
  });
});

describe('counterSettingsVectors — effectiveTitleTemplates', () => {
  it.each(V.effectiveTitleTemplates as any[])('$name', (v: any) => {
    expect(effectiveTitleTemplates(v.root)).toEqual(v.expected);
  });
});

describe('counterSettingsVectors — renderCounterTitle', () => {
  it.each(V.renderCounterTitle as any[])('$name', (v: any) => {
    expect(renderCounterTitle(v.root, v.goal)).toBe(v.expected);
  });
});

describe('counterSettingsVectors — counterDisplayName', () => {
  it.each(V.counterDisplayName as any[])('$name', (v: any) => {
    expect(counterDisplayName(v.root)).toBe(v.expected);
  });
});

describe('counterSettingsVectors — derivedTimeframeGoals', () => {
  it.each(V.derivedTimeframeGoals as any[])('$name', (v: any) => {
    expect(derivedTimeframeGoals(v.root)).toEqual(v.expected);
  });
});

describe('counterSettingsVectors — resolveCounterDefaultGoal', () => {
  it.each(V.resolveCounterDefaultGoal as any[])('$name', (v: any) => {
    expect(resolveCounterDefaultGoal(v.root, v.timeframe)).toBe(v.expected);
  });
});

describe('counterSettingsVectors — template-aware isAutoCounterTitle', () => {
  it('pins both outcomes', () => {
    expect(new Set((V.isAutoCounterTitle as any[]).map((v) => v.expected))).toEqual(new Set([true, false]));
  });

  it.each(V.isAutoCounterTitle as any[])('$name', (v: any) => {
    const r = v.root;
    expect(isAutoCounterTitle(v.title, r.action ?? '', v.goal, r.unit ?? '', r.countKind ?? 'discrete', r)).toBe(
      v.expected,
    );
  });
});

describe('counterSettingsVectors — counterCopyTitle with root templates', () => {
  it.each(V.counterCopyTitle as any[])('$name', (v: any) => {
    expect(counterCopyTitle(v.member, v.newMaxCount)).toBe(v.expected);
  });
});

describe('inert for untouched counters', () => {
  // Every pre-existing generator vector renders identically through the
  // template path when the root stores no templates (the byte-identity pin
  // the rewire rests on — the expected strings are the fixture's, not a
  // second call of the same function).
  it.each((TITLE_V.generateCounterTaskTitle as any[]).filter((v) => !(v.providedTitle ?? '').trim()))(
    '$name',
    (v: any) => {
      const root = { action: v.action ?? '', unit: v.unit ?? '', countKind: v.countKind ?? 'discrete' };
      expect(renderCounterTitle(root, v.maxCount ?? null)).toBe(v.expected);
      expect(generateCounterTaskTitle(v.action ?? '', v.maxCount ?? null, v.unit ?? '', undefined, v.countKind)).toBe(
        v.expected,
      );
    },
  );

  it('formatTitleCount is locale-free', () => {
    expect(formatTitleCount(1234.5, 'continuous')).toBe('1234.5');
    expect(formatTitleCount(61, 'duration')).toBe('1h 1m');
  });
});

describe('counterSettingsVectors — the counter sheet draft (UI PR)', () => {
  it.each(V.counterSettingsDefaults as any[])('defaults: $name', (v: any) => {
    expect(counterSettingsDefaults(v.context, v.draft)).toEqual(v.expected);
  });

  it.each(V.storedCounterSettingsFromDraft as any[])('stored: $name', (v: any) => {
    expect(storedCounterSettingsFromDraft(v.context, v.draft)).toEqual(v.expected);
  });

  it('a draft seeded from a root round-trips through store', () => {
    const root = {
      action: 'Read', unit: 'books', counterName: 'Books', titleTemplateSingular: 'Read #N book',
      titleTemplatePlural: 'Read #N novels', timeframeGoals: { weekly: 2, yearly: 0 },
    };
    const draft = counterSettingsDraftFromRoot(root);
    expect(draft).toEqual({ name: 'Books', singular: 'Read #N book', plural: 'Read #N novels', goals: { weekly: 2 } });
    expect(storedCounterSettingsFromDraft(root, draft)).toEqual(storedCounterSettings(root));
  });

  it('blank / whitespace stored fields seed as unset', () => {
    expect(counterSettingsDraftFromRoot({ counterName: '  ', titleTemplatePlural: null })).toEqual({
      name: '', singular: '', plural: '', goals: {},
    });
    expect(storedCounterSettings({ counterName: ' ', timeframeGoals: { daily: 0 } })).toEqual({});
  });

  it('changedCounterSettingsKeys lists only the keys whose stored value differs', () => {
    const before = { counterName: 'Books', timeframeGoals: { weekly: 2 } };
    expect(changedCounterSettingsKeys(before, before)).toEqual([]);
    expect(changedCounterSettingsKeys(before, { timeframeGoals: { weekly: 2 } })).toEqual(['counterName']);
    expect(changedCounterSettingsKeys(before, { counterName: 'Books', timeframeGoals: { weekly: 3 } })).toEqual(['timeframeGoals']);
    expect(changedCounterSettingsKeys(before, { counterName: 'Books', timeframeGoals: { weekly: 2, daily: 1 } })).toEqual(['timeframeGoals']);
    expect(changedCounterSettingsKeys({}, { titleTemplateSingular: 'Read #N book', titleTemplatePlural: 'Read #N novels' }))
      .toEqual(['titleTemplateSingular', 'titleTemplatePlural']);
  });
});
