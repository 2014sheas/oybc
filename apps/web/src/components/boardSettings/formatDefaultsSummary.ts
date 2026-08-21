/**
 * Pure, testable summary line for a core-board-defaults row. Mirrors iOS
 * `BoardSettingsView.formatDefaultsSummary(resolvedCount:poolNames:)`
 * verbatim (`apps/ios/OYBC/Views/ProfileTab/BoardSettingsView.swift`) — a
 * 2026-08 web↔iOS parity fix that replaced the web-only task-title preview
 * ("Task A, Task B +2 more") with iOS's count + pool summary.
 *
 * Copy rule (owner-enforced, docs/POOLS_RECURRING.md §Behavior invariants):
 * "No default tasks", never "Not set"; "from", never "deals from".
 */
export function formatDefaultsSummary(resolvedCount: number, poolNames: string[]): string {
  if (resolvedCount <= 0) return 'No default tasks';
  const taskPart = `${resolvedCount} default task${resolvedCount === 1 ? '' : 's'}`;
  if (poolNames.length === 0) return taskPart;
  const poolPart =
    poolNames.length === 1 ? `from ${poolNames[0]}` : `from ${poolNames.length} pools`;
  return `${taskPart} · ${poolPart}`;
}
