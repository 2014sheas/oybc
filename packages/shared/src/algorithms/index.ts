// Compat shim (PLAY_TRANSITION.md T1): bingo-core's symbols intentionally
// re-export through BOTH this barrel and constants/index.ts — identical
// bindings, so TS tolerates the overlap. Don't "dedupe" one path away:
// consumers import the functions from algorithms and the enums/constants
// from constants.
export * from '@oybc/bingo-core';

export { generateCounterTaskTitle } from './taskTitle';

export {
  evaluateCompositeTree,
} from './compositeEvaluation';

// ===== Compound tasks unification =====
export {
  evaluateCompound,
} from './compoundEvaluation';

export {
  findTransitiveParentCompounds,
  findAffectedBoardIds,
  computeBoardStatsUpdate,
  computeSealedCompletedCells,
} from './derivationPass';

export type { BoardStatsUpdate } from './derivationPass';

// ===== Windowed Completion — task events + windowed evaluation (PR A) =====
export {
  isEventOwningTask,
  resolveTaskWindowState,
  backstopWindowMs,
  computeBackstopDeadlineMs,
  buildSealImmuneWindows,
  isOccurredAtSealImmune,
  BACKSTOP_MAX_MS,
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

export { hasCycle } from './cycleDetection';

export type {
  CycleCheckCandidate,
  CycleCheckContext,
  CycleCheckResult,
} from './cycleDetection';

export {
  progressTaskToCompound,
  taskStepToCompoundChild,
  compositeTaskToTask,
  compositeNodeToCompoundChild,
  backfillTaskCompletion,
  collectEverCompletedStepIds,
  shouldBackfillStepLinkedTaskAsComplete,
} from './migrationHelpers';

export type {
  LegacyBoardTaskCompletion,
  CompletionBackfillResult,
} from './migrationHelpers';
// ===== End compound tasks unification =====

export {
  calculateCountingRollup,
  calculateProgressRollup,
} from './rollup';

export type {
  CountingRollupResult,
  ProgressRollupResult,
} from './rollup';

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

export { isTaskExpired } from './taskExpiry';

export { computeBrowsableTasks } from './browsableTasks';

// ===== Phase 1 + Phase 3 — Shared counter =====
export { deriveDisplayedCount, propagateIncrement } from './sharedCounter';

export type {
  PropagateIncrementSource,
  PropagateIncrementLinkedTask,
  LinkedTaskIncrementResult,
} from './sharedCounter';

// ===== Phase 4 — Shared counter sync / additive-merge conflict resolution =====
export { additiveMergeCount, needsAdditiveMerge } from './sharedCounterMerge';

export type { MergeCountResult } from './sharedCounterMerge';

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
export { findLinkableCounter } from './linkableCounter';

export type { LinkableCounter, FindLinkableCounterInput } from './linkableCounter';

// ===== Sync contract — LWW conflict resolution (C4 / issue #261) =====
export { resolveConflict } from './lwwResolve';

export type { SyncableEntity, ConflictResult } from './lwwResolve';
