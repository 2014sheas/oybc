import { z } from 'zod';

/**
 * Zod schema for `BoardSource` (Board Sources rework, docs/BOARD_SOURCES.md
 * P1) — mirrors `../types/boardSource.ts`. Used by the
 * RecurringBoardTemplate schemas (the `sources` field) and by the
 * draft-blob v2 codec's shape check on web.
 *
 * Lives in its own file (not schemas.ts) because schemas.ts is a frozen
 * god-file at its size cap (ROADMAP B6) — the `entitlement.ts` precedent.
 *
 * Bounds:
 * - `min`: non-negative integer. The board-size cap (`min ≤
 *   fillableCellCount`) is a UI/resolve-time clamp, not a schema bound —
 *   the schema can't see the board size, and a too-large persisted min is
 *   clamped harmlessly at resolve time.
 * - `max`: non-negative integer or `null` (the "all" latch). `min ≤ max`
 *   is enforced when max is numeric; `null` means "all", which always
 *   satisfies any min at resolve time (both are clamped to availability).
 * - `excludedTaskIds`: no duplicates (same convention as every id array
 *   on the template schemas).
 */
export const BoardSourceSchema = z
  .object({
    sourceId: z.string().uuid(),
    kind: z.union([z.literal('pool'), z.literal('board')]),
    min: z.number().int().min(0),
    max: z.number().int().min(0).nullable(),
    excludedTaskIds: z.array(z.string().uuid()),
    filter: z.union([z.literal('all'), z.literal('todo')]),
  })
  .refine(
    (s) => new Set(s.excludedTaskIds).size === s.excludedTaskIds.length,
    { message: 'excludedTaskIds must not contain duplicates' },
  )
  .refine((s) => s.max === null || s.min <= s.max, {
    message: 'min must not exceed a numeric max',
  });

/**
 * The `sources` array as carried on RecurringBoardTemplate schemas and the
 * draft-blob v2 codec: optional (absent = record predates the Board
 * Sources stamp — `sourcesForRecord` derives from the legacy trio), with
 * no duplicate `sourceId`s (one row per pulled source).
 */
export const BoardSourcesArraySchema = z
  .array(BoardSourceSchema)
  .refine(
    (arr) => new Set(arr.map((s) => s.sourceId)).size === arr.length,
    { message: 'sources must not contain duplicate sourceIds' },
  );
