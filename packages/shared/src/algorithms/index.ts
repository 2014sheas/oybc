export {
  detectBingos,
  formatBingoMessage,
  getHighlightedSquares,
} from './bingoDetection';

export type { BingoDetectionResult } from './bingoDetection';

export { fisherYatesShuffle } from './shuffle';

export {
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
} from './centerSquare';

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
} from './derivationPass';

export type { BoardStatsUpdate } from './derivationPass';

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
