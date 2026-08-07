// Compat shim (PLAY_TRANSITION.md T1): bingo-core's symbols intentionally
// re-export through BOTH this barrel and constants/index.ts — identical
// bindings, so TS tolerates the overlap. Don't "dedupe" one path away:
// consumers import the functions from algorithms and the enums/constants
// from constants.
export * from '@oybc/bingo-core';

export { generateCounterTaskTitle } from './taskTitle';

// ===== Pair-derived counter display names (R1 — counters refresh) =====
export { formatCounterName } from './counterName';

// ===== Compound tasks unification =====
export {
  evaluateCompound,
} from './compoundEvaluation';

export {
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  computeSealedCompletedCells,
  computeBoardGrid,
} from './derivationPass';

export type { BoardStatsUpdate, CellState, AchievementCellBadge } from './derivationPass';

// ===== Windowed Completion — task events + windowed evaluation (PR A) =====
export {
  isEventOwningTask,
  resolveTaskWindowState,
  backstopWindowMs,
  computeBackstopDeadlineMs,
  buildSealImmuneWindows,
  isOccurredAtSealImmune,
  BACKSTOP_MAX_MS,
  SEED_EVENT_OCCURRED_AT,
} from './taskEvents';

export type {
  TaskWindowState,
  CompoundWindowContext,
  WindowEvaluationContext,
  SealImmuneWindow,
} from './taskEvents';

// ===== Windowed Completion — board sealing detection (PR C) =====
export {
  isBoardSealable,
  isBoardClosingOut,
  isBoardPastBackstop,
} from './sealing';

export type { SealableBoardFields } from './sealing';

export { uuidv5, OYBC_NAMESPACE } from './uuidv5';

export { backfillTaskEventId, buildBackfillTaskEvent } from './migrationHelpers';

export {
  migrationDefaultPoolToPoolId,
  migrationDefaultPoolToCoreBoardDefaultId,
  migrationTemplateToPoolId,
} from './migrationHelpers';

export { hasCycle } from './cycleDetection';

export type {
  CycleCheckCandidate,
  CycleCheckContext,
  CycleCheckResult,
} from './cycleDetection';
// ===== End compound tasks unification =====

export {
  toLocalISO,
  getDayBoundaries,
  getWeekBoundaries,
  getMonthBoundaries,
  getYearBoundaries,
  getTimeframeBoundaries,
  stepWindow,
  isWithinTimeframe,
  isTimeframeExpired,
  formatTimeframeLabel,
  formatRecurringCadence,
} from './calendarBoundaries';

export type {
  WeekStartDay,
  TimeframeBoundaries,
} from './calendarBoundaries';

export {
  PARENT_TIMEFRAMES,
  findPendingRecurringBoards,
  getCoreBoardSlots,
  getParentBoards,
} from './recurringBoards';

export type { CoreBoardSlot, PendingRecurringBoard } from './recurringBoards';

export {
  STREAK_TIMEFRAMES,
  computeStreak,
  computeAllStreaks,
  computeLongestStreak,
  compactStreakLabel,
} from './streaks';

export type { StreakPair, StreaksByTimeframe } from './streaks';

export {
  findTemplatesPendingSpawn,
  validateSpawnPool,
  buildSpawnPlacement,
  deriveSpawnedBoardName,
} from './recurringBoardTemplates';

export type {
  PendingTemplateSpawn,
  SpawnPoolValidation,
  SpawnPoolFailureReason,
  BuildSpawnPlacementArgs,
} from './recurringBoardTemplates';

// ===== Task Pools + Recurring Boards Rework (P1) — mix resolver =====
export {
  resolveMix,
  clearRemovalsForUntoggle,
  isLegacyShapedRecord,
  mergeLegacyPoolTaskIds,
  clampMintedPoolName,
} from './poolMix';

export type { PoolMixSource, ResolveMixResult } from './poolMix';

// ===== Task Pools + Recurring Boards Rework (P2) — pool health =====
export { computePoolHealth, formatPoolShortSummary } from './poolHealth';

export type {
  PoolHealthConsumer,
  PoolHealthResult,
  ComputePoolHealthInput,
} from './poolHealth';

export { isTaskExpired } from './taskExpiry';

export { computeBrowsableTasks, isGoalLessCounter } from './browsableTasks';

// ===== Phase 1 + Phase 3 — Shared counter =====
export { deriveDisplayedCount, propagateIncrement } from './sharedCounter';

export type {
  PropagateIncrementSource,
  PropagateIncrementLinkedTask,
  LinkedTaskIncrementResult,
} from './sharedCounter';

// Phase 4's `sharedCounterMerge` (additiveMergeCount / needsAdditiveMerge) was
// retired by Windowed Completion — counting-task conflicts now resolve by
// union-of-events, not additive merge (docs/WINDOWED_COMPLETION.md §Shared
// counters interaction). The module + its tests/fixtures were deleted in WC PR D.

// ===== Shared Counters — Hub / Detail read-model builder (P1) =====
export { buildSharedCounterGroups } from './sharedCounterGroups';

export type {
  SharedCounterGroup,
  SharedCounterMemberTask,
  BuildSharedCounterGroupsInput,
} from './sharedCounterGroups';

// ===== Shared Counters — passive-completion arrival detection (P3) =====
export { detectCounterArrivals, snapshotCounterSquares } from './counterArrivals';

export type {
  ArrivalSquare,
  DetectCounterArrivalsInput,
  ArrivedCounter,
  CounterArrivalResult,
} from './counterArrivals';

// ===== Shared Counters — "link a new task to an existing counter" match =====
export { classifyCounterCreateMatch, findLinkableCounter } from './linkableCounter';

export type {
  CounterCreateMatch,
  LinkableCounter,
  FindLinkableCounterInput,
} from './linkableCounter';

// ===== Sync contract — LWW conflict resolution (C4 / issue #261) =====
export { resolveConflict } from './lwwResolve';

export type { SyncableEntity, ConflictResult } from './lwwResolve';

// ===== Counters UX refresh (R2) — milestone, daily totals, last-entry =====
export { nextCounterMilestone, counterMilestoneProgress } from './counterMilestone';

export type { CounterMilestoneProgress } from './counterMilestone';

export { deriveCounterDailyTotals } from './counterDailyTotals';

export type {
  CounterDailyTotal,
  CounterDailyTotalsResult,
  DeriveCounterDailyTotalsOptions,
} from './counterDailyTotals';

export { selectLastIncrementEntry } from './lastCounterLogEntry';

// ===== Board-integrity PR-2 — deterministic placement winner rule + repair =====
export {
  comparePlacementPrecedence,
  pickPlacementWinner,
  resolvePlacements,
  computePlacementIntegrityRepair,
} from './placementResolution';

export type { PlacementIntegrityRepairResult } from './placementResolution';
