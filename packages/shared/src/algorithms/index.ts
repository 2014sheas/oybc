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
  isWithinTimeframe,
  isTimeframeExpired,
  formatTimeframeLabel,
} from './calendarBoundaries';

export type {
  WeekStartDay,
  TimeframeBoundaries,
} from './calendarBoundaries';

export {
  PARENT_TIMEFRAMES,
  findPendingRecurringBoards,
  getParentBoards,
} from './recurringBoards';

export type { PendingRecurringBoard } from './recurringBoards';
