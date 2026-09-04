import { z } from 'zod';
import {
  BoardSizeSchema,
  RecurringTimeframeSchema,
  RecurringCenterSquareTypeSchema,
} from './schemas';
import { BoardSourcesArraySchema } from './boardSource';

/**
 * RecurringBoardTemplate object schemas — moved out of the frozen
 * `schemas.ts` god-file in the Board Sources rework (P1), which also adds
 * the optional `sources` field (docs/BOARD_SOURCES.md §Data model). The
 * two field schemas they build on (`RecurringTimeframeSchema`,
 * `RecurringCenterSquareTypeSchema`) stay in `schemas.ts` — other schemas
 * there share them.
 *
 * P1 (Task Pools rework) legacy trio — `poolIds` / `manualTaskIds` /
 * `removedTaskIds` — stays additive and optional on every schema so a
 * legacy (`seedTaskIds`-only) payload still validates. Each array gets its
 * own no-dup refine, mirroring `seedTaskIds`'s. `sources` (Board Sources
 * P1) is optional the same way: absent = the record predates the sources
 * stamp and `sourcesForRecord` derives it from the trio on read.
 */
const poolIdsNoDup = (data: { poolIds?: string[] }): boolean =>
  data.poolIds === undefined || new Set(data.poolIds).size === data.poolIds.length;
const manualTaskIdsNoDup = (data: { manualTaskIds?: string[] }): boolean =>
  data.manualTaskIds === undefined ||
  new Set(data.manualTaskIds).size === data.manualTaskIds.length;
const removedTaskIdsNoDup = (data: { removedTaskIds?: string[] }): boolean =>
  data.removedTaskIds === undefined ||
  new Set(data.removedTaskIds).size === data.removedTaskIds.length;

export const CreateRecurringBoardTemplateInputSchema = z.object({
  name: z.string().trim().min(1).max(120),
  timeframe: RecurringTimeframeSchema,
  boardSize: BoardSizeSchema,
  centerSquareType: RecurringCenterSquareTypeSchema,
  isRandomized: z.boolean(),
  seedTaskIds: z.array(z.string().uuid()).min(1),
  isActive: z.boolean(),
  poolIds: z.array(z.string().uuid()).optional(),
  manualTaskIds: z.array(z.string().uuid()).optional(),
  removedTaskIds: z.array(z.string().uuid()).optional(),
  sources: BoardSourcesArraySchema.optional(),
}).refine(
  (data) => {
    // No duplicate seedTaskIds — each pool entry must reference a distinct
    // Task. The spawn path treats duplicates as an error class equivalent
    // to "pool too small" (a 25-pool with 5 dups only places 20 unique tasks).
    return new Set(data.seedTaskIds).size === data.seedTaskIds.length;
  },
  { message: 'seedTaskIds must not contain duplicates' },
).refine(
  poolIdsNoDup,
  { message: 'poolIds must not contain duplicates' },
).refine(
  manualTaskIdsNoDup,
  { message: 'manualTaskIds must not contain duplicates' },
).refine(
  removedTaskIdsNoDup,
  { message: 'removedTaskIds must not contain duplicates' },
);

export const UpdateRecurringBoardTemplateInputSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  timeframe: RecurringTimeframeSchema.optional(),
  boardSize: BoardSizeSchema.optional(),
  centerSquareType: RecurringCenterSquareTypeSchema.optional(),
  isRandomized: z.boolean().optional(),
  seedTaskIds: z.array(z.string().uuid()).min(1).optional(),
  isActive: z.boolean().optional(),
  poolIds: z.array(z.string().uuid()).optional(),
  manualTaskIds: z.array(z.string().uuid()).optional(),
  removedTaskIds: z.array(z.string().uuid()).optional(),
  sources: BoardSourcesArraySchema.optional(),
}).refine(
  (data) => {
    if (data.seedTaskIds === undefined) return true;
    return new Set(data.seedTaskIds).size === data.seedTaskIds.length;
  },
  { message: 'seedTaskIds must not contain duplicates' },
).refine(
  poolIdsNoDup,
  { message: 'poolIds must not contain duplicates' },
).refine(
  manualTaskIdsNoDup,
  { message: 'manualTaskIds must not contain duplicates' },
).refine(
  removedTaskIdsNoDup,
  { message: 'removedTaskIds must not contain duplicates' },
);

export const RecurringBoardTemplateSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(120),
  timeframe: RecurringTimeframeSchema,
  boardSize: BoardSizeSchema,
  centerSquareType: RecurringCenterSquareTypeSchema,
  isRandomized: z.boolean(),
  seedTaskIds: z.array(z.string().uuid()),
  // P1 — additive, optional generalized-source fields. See
  // types/recurringBoardTemplate.ts for the mix formula + "legacy shape".
  poolIds: z.array(z.string().uuid()).optional(),
  manualTaskIds: z.array(z.string().uuid()).optional(),
  removedTaskIds: z.array(z.string().uuid()).optional(),
  // Board Sources P1 — the canonical persisted shape going forward
  // (docs/BOARD_SOURCES.md). Written alongside the trio during P1.
  sources: BoardSourcesArraySchema.optional(),
  lastSpawnedWindowKey: z.string().nullable(),
  isActive: z.boolean(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
}).refine(
  poolIdsNoDup,
  { message: 'poolIds must not contain duplicates' },
).refine(
  manualTaskIdsNoDup,
  { message: 'manualTaskIds must not contain duplicates' },
).refine(
  removedTaskIdsNoDup,
  { message: 'removedTaskIds must not contain duplicates' },
);
