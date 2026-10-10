import { counterDisplayName, resolveCountKind, type Task } from '@oybc/shared';
import type { KindTagProps } from './KindTag';

/**
 * The kind tag props for an existing linked row: the family root's kind,
 * pair-derived counter name (title fallback) and all-time total — the same
 * name / lifetime the auto-link hint shows on a create (`findLinkableCounter`).
 * Falls back to the row's own kind, without the meta line, while the root
 * isn't in `pool`. iOS twin: `KindTagView(linkedTask:root:)`.
 *
 * @param task - The linked row (`sharedCounterId` set).
 * @param pool - Tasks to find the root in.
 * @returns Props for `KindTag`.
 */
export function linkedKindTagProps(task: Task, pool: readonly Task[]): KindTagProps {
  const root = task.sharedCounterId ? pool.find((t) => t.id === task.sharedCounterId) : undefined;
  if (!root) return { kind: resolveCountKind(task) };
  return {
    kind: resolveCountKind(root),
    counterName: counterDisplayName(root),
    lifetime: root.currentCount ?? 0,
  };
}
