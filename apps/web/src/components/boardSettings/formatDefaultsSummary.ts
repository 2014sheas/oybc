import { CenterSquareType, type CoreBoardSetupDefaults } from '@oybc/shared';

/**
 * Pure, testable summary line for a core-board-defaults row. Mirrors iOS
 * `BoardSettingsView.formatDefaultsSummary(resolvedCount:poolNames:setup:)`
 * verbatim (`apps/ios/OYBC/Views/ProfileTab/BoardSettingsView.swift`) — a
 * 2026-08 web↔iOS parity fix that replaced the web-only task-title preview
 * ("Task A, Task B +2 more") with iOS's count + pool summary.
 *
 * Copy rule (owner-enforced, docs/POOLS_RECURRING.md §Behavior invariants):
 * "No default tasks", never "Not set"; "from", never "deals from".
 *
 * @param resolvedCount - Number of tasks the row's pools + defaults resolve to.
 * @param poolNames - Names of the pulled pools (0, 1, or many).
 * @param setup - The RESOLVED size + centre when the timeframe explicitly
 *   overrides either (`hasExplicitCoreBoardSetup` → `resolveCoreBoardSetupDefaults`);
 *   omit for an inheriting timeframe, which shows no suffix.
 * @returns e.g. `"4 default tasks · from Morning Pool · 3×3 · free space"`.
 */
export function formatDefaultsSummary(
  resolvedCount: number,
  poolNames: string[],
  setup?: CoreBoardSetupDefaults,
): string {
  const base = formatTasksPart(resolvedCount, poolNames);
  return setup ? `${base} · ${formatSetupSuffix(setup)}` : base;
}

function formatTasksPart(resolvedCount: number, poolNames: string[]): string {
  if (resolvedCount <= 0) return 'No default tasks';
  const taskPart = `${resolvedCount} default task${resolvedCount === 1 ? '' : 's'}`;
  if (poolNames.length === 0) return taskPart;
  const poolPart =
    poolNames.length === 1 ? `from ${poolNames[0]}` : `from ${poolNames.length} pools`;
  return `${taskPart} · ${poolPart}`;
}

/**
 * The size / centre suffix on its own: `"3×3 · free space"`, `"5×5 · no
 * free space"`, or a bare `"4×4"` (an even board has no centre concept, so
 * its centre value is never described).
 *
 * @param setup - A resolved size + centre pair.
 * @returns The suffix text.
 */
export function formatSetupSuffix(setup: CoreBoardSetupDefaults): string {
  const size = `${setup.boardSize}×${setup.boardSize}`;
  if (setup.boardSize % 2 === 0) return size;
  return setup.centerType === CenterSquareType.FREE ? `${size} · free space` : `${size} · no free space`;
}
