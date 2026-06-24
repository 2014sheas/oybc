/**
 * Board status lifecycle
 */
export enum BoardStatus {
  DRAFT = 'draft',           // Board being created, not yet active
  ACTIVE = 'active',         // Currently playable board
  COMPLETED = 'completed',   // All tasks completed (greenlog)
  ARCHIVED = 'archived'      // User archived the board
}

/**
 * Task type definitions
 *
 * COMPOUND is the canonical type that subsumes the former Progress (ordered
 * step list) and Composite (operator-based) task models. A Progress-style
 * task is a COMPOUND with `operator='AND'` + `isOrdered=true`; a Composite
 * is a COMPOUND with `operator='AND'/'OR'/'M_OF_N'` + `isOrdered=false`.
 *
 * ACHIEVEMENT (Phase 6.3) is a cross-board watcher: the Task carries a
 * `referencedBoardId` XOR `referencedTemplateId` and completes when the
 * referenced board (or every in-window spawn of the referenced template)
 * is greenlogged. Achievement tasks are placed via the wizard like any
 * other type — `BoardTask` remains a pure placement record.
 *
 * Migration helpers and pull-path validators that need to recognise legacy
 * `'progress'` rows from pre-unification storage compare against the literal
 * string `'progress'` directly — there is no enum value for it.
 */
export enum TaskType {
  NORMAL = 'normal',           // Simple completion task
  COUNTING = 'counting',       // Tasks with counts (e.g., "Read 100 pages")
  COMPOUND = 'compound',       // Compound task: multi-child with operator (AND/OR/M_OF_N) and ordering
  ACHIEVEMENT = 'achievement', // Phase 6.3 cross-board watcher (specific board XOR recurring template)
}

/**
 * Board timeframe options
 */
export enum Timeframe {
  DAILY = 'daily',
  WEEKLY = 'weekly',
  MONTHLY = 'monthly',
  YEARLY = 'yearly',
  CUSTOM = 'custom',         // Custom date range
  INDEFINITE = 'indefinite'  // No end date — ongoing board that never expires
}

/**
 * Center square behavior
 */
export enum CenterSquareType {
  FREE = 'free',                  // Auto-completed (traditional bingo), shows "FREE SPACE"
  CUSTOM_FREE = 'custom_free',    // Auto-completed with custom name, locked
  CHOSEN = 'chosen',              // User-chosen center task, NOT auto-completed, toggleable
  NONE = 'none'                   // No center square (even-sized boards or no special treatment)
}

/**
 * Bingo line types (for detection)
 */
export enum BingoLineType {
  ROW = 'row',
  COLUMN = 'column',
  DIAGONAL = 'diagonal'
}

/**
 * Sync operation types
 */
export enum SyncOperationType {
  CREATE = 'create',
  UPDATE = 'update',
  DELETE = 'delete'
}

/**
 * Sync status
 */
export enum SyncStatus {
  PENDING = 'pending',
  IN_PROGRESS = 'in_progress',
  COMPLETED = 'completed',
  FAILED = 'failed'
}

/**
 * Composite task operator types
 */
export enum OperatorType {
  AND = 'AND',       // All children must be complete
  OR = 'OR',         // Any child must be complete
  M_OF_N = 'M_OF_N' // M of N children must be complete (requires threshold)
}

/**
 * Phase 6.3 — Achievement-task completion trigger.
 *
 * Determines what counts as the watched board (or spawn) being "done":
 *   - BINGO: at least one bingo line on the watched board (`linesCompleted > 0`)
 *   - GREENLOG: full board completion (`status === BoardStatus.COMPLETED`)
 *
 * For specific-board mode, the trigger is evaluated against the single
 * referenced board. For recurring-template mode, the trigger is
 * evaluated against each in-window spawn and combined with
 * `Task.requiredCount` (cell completes when N spawns each meet the
 * trigger). Default when unset is GREENLOG (matches the pre-trigger
 * shipped behavior).
 */
export enum AchievementTrigger {
  BINGO = 'bingo',
  GREENLOG = 'greenlog',
}
