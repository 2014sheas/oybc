/** How many pool task titles a template row previews before collapsing
 *  to a "+k more" chip. Shared by the row renderer and the page-level
 *  preview computation. iOS mirror: `RecurringBoardTemplatesViewModel`. */
export const POOL_PREVIEW_LIMIT = 3;

export interface PoolPreview {
  /** Up to `limit` resolved titles, in seedTaskIds order. */
  titles: string[];
  /** Count of additional RESOLVED titles beyond `titles` (0 ⇒ no
   *  "+k more" chip). Resolved-based, not raw pool length — unresolvable
   *  ids (soft-deleted tasks) already surface via the attention badge,
   *  so the overflow chip only counts titles that actually exist.
   *  Mirrors iOS `RecurringBoardTemplatesViewModel.computePoolPreview`. */
  overflow: number;
}

/**
 * Resolve the first few pool task titles for a template row's compact
 * pool preview.
 *
 * Walks `seedTaskIds` in order, resolving each id against `taskMap` and
 * skipping unresolvable ids (soft-deleted tasks stay in the pool array
 * by design — see `RecurringBoardTemplate.seedTaskIds`).
 *
 * @param seedTaskIds - The template's pool, in stored order.
 * @param taskMap - id → task lookup (only `title` is read).
 * @param limit - Maximum titles to return (defaults to POOL_PREVIEW_LIMIT).
 * @returns The first `limit` resolved titles + the resolved overflow count.
 */
export function computePoolPreview(
  seedTaskIds: string[],
  taskMap: Record<string, { title: string } | undefined>,
  limit: number = POOL_PREVIEW_LIMIT,
): PoolPreview {
  const resolved: string[] = [];
  for (const id of seedTaskIds) {
    const found = taskMap[id];
    if (found) resolved.push(found.title);
  }
  return {
    titles: resolved.slice(0, limit),
    overflow: Math.max(0, resolved.length - limit),
  };
}
