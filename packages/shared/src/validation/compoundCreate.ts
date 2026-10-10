import { z } from 'zod';
import { OperatorType, TaskType, Timeframe } from '../constants/enums';
import { CountKindSchema, positiveCount, nonNegativeCount, countFieldsMatchKind } from './countValue';

/**
 * Compound creation input schemas — split out of `schemas.ts` (which
 * re-exports them) along their seam to keep it under the file-size ceiling.
 */
export const AutoCreateCompoundChildTaskSchema = z.object({
  type: z.enum([TaskType.NORMAL, TaskType.COUNTING]),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  action: z.string().min(1).max(50).optional(),
  unit: z.string().min(1).max(50).optional(),
  maxCount: positiveCount().optional(),
  // R1 counters refresh — auto-link (see AutoCreateCompoundChildTask doc).
  sharedCounterId: z.string().uuid().nullable().optional(),
  baseline: nonNegativeCount().nullable().optional(),
  countKind: CountKindSchema.optional(),
}).refine(
  (data) => {
    if (data.type === TaskType.COUNTING) {
      return data.action !== undefined && (data.unit !== undefined || data.countKind === 'duration') && data.maxCount !== undefined;
    }
    return true;
  },
  { message: 'Counting child tasks require action, unit, and maxCount' },
).refine(
  countFieldsMatchKind,
  { message: 'Whole-number kinds need whole goals' },
).refine(
  (data) => (data.sharedCounterId != null) === (data.baseline != null),
  { message: 'sharedCounterId and baseline must both be set or both be absent' },
);

export const CreateCompoundChildEntrySchema = z.object({
  childTaskId: z.string().uuid().optional(),
  autoCreate: AutoCreateCompoundChildTaskSchema.optional(),
}).refine(
  (data) => (data.childTaskId !== undefined) !== (data.autoCreate !== undefined),
  { message: 'CreateCompoundChildEntry must specify exactly one of childTaskId or autoCreate' },
);

export const CreateCompoundTaskInputSchema = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  operator: z.nativeEnum(OperatorType),
  threshold: z.number().int().positive().optional(),
  // One sub-task is enough (2026-10-06, owner ask); zero stays blocked —
  // except for a container that counts toward a counter (refinement below).
  children: z.array(CreateCompoundChildEntrySchema),
  // "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3a).
  countsTowardCounterId: z.string().uuid().optional(),
  countsTowardAmount: z.number().int().positive().optional(),
  // Phase 6.Y — Timeboxed Tasks. Optional; when set, the parent
  // compound AND all inline-created children inherit this triple at
  // creation time (see createCompound in db/operations/tasks.ts).
  timeframe: z.nativeEnum(Timeframe).optional(),
  startDate: z.string().optional(),
  endDate: z.string().optional(),
}).refine(
  (data) => data.children.length >= 1 || data.countsTowardCounterId != null,
  { message: 'A compound task needs a sub-task', path: ['children'] },
).refine(
  (data) => {
    if (data.operator === OperatorType.M_OF_N) {
      return data.threshold !== undefined && data.threshold >= 1 && data.threshold <= data.children.length;
    }
    return true;
  },
  { message: "operator='M_OF_N' requires threshold in [1, children.length]" },
).refine(
  (data) => {
    // No duplicate childTaskIds.
    const ids = data.children.map((c) => c.childTaskId).filter((id): id is string => id !== undefined);
    return new Set(ids).size === ids.length;
  },
  { message: 'Compound children must not contain duplicate childTaskId references' },
);
