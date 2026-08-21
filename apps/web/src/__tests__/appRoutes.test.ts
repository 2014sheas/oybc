import { describe, expect, it } from 'vitest';

/**
 * P7 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Migration item 4 "Routes … removed; `/profile/board-settings` added")
 * — a source-level lock on the route retirement, since this repo's Vitest
 * harness has no component-render support (`environment: 'node'` — see
 * `poolPullLogic.ts`'s docstring) and so can't mount `<App />` to assert
 * against `react-router`'s resolved route tree directly. Reading the
 * router config as text (via Vite's `?raw` import — no `@types/node`
 * dependency needed) is a deliberately blunt substitute: it still fails
 * loudly if either retired route is ever re-added or the new one is
 * removed/renamed, which is the regression this test exists to catch.
 */
const appSourceModules = import.meta.glob('../App.tsx', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;
const appSource = Object.values(appSourceModules)[0];

describe('App.tsx route table', () => {
  it('loaded the App.tsx source for inspection', () => {
    expect(typeof appSource).toBe('string');
    expect(appSource.length).toBeGreaterThan(0);
  });

  it('no longer registers the retired Recurring templates / Default pools routes', () => {
    expect(appSource).not.toContain('/profile/recurring-templates');
    expect(appSource).not.toContain('/profile/default-pools');
    expect(appSource).not.toContain('RecurringTemplatesPage');
    expect(appSource).not.toContain('DefaultPoolsListPage');
    expect(appSource).not.toContain('DefaultPoolEditorPage');
  });

  it('registers the new Board settings route', () => {
    expect(appSource).toContain('/profile/board-settings');
    expect(appSource).toContain('BoardSettingsPage');
  });
});
