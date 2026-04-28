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
 * COMPOUND is the canonical task type that subsumes PROGRESS and the legacy
 * separate composite_tasks hierarchy. Both fold into compound: PROGRESS tasks
 * become COMPOUND with operator=AND, isOrdered=true; legacy composite tasks
 * are migrated to COMPOUND in Phase 6+.
 */
export enum TaskType {
  NORMAL = 'normal',         // Simple completion task
  COUNTING = 'counting',     // Tasks with counts (e.g., "Read 100 pages")
  /**
   * @deprecated Transitional alias kept for the duration of the compound-tasks
   * unification refactor; downstream callers in apps/web and apps/ios still
   * reference TaskType.PROGRESS. Removed in Phase 8 once all callers migrate
   * to TaskType.COMPOUND with isOrdered=true.
   */
  PROGRESS = 'progress',
  COMPOUND = 'compound'      // Compound task: multi-child with operator (AND/OR/M_OF_N) and ordering
}

/**
 * Board timeframe options
 */
export enum Timeframe {
  DAILY = 'daily',
  WEEKLY = 'weekly',
  MONTHLY = 'monthly',
  YEARLY = 'yearly',
  CUSTOM = 'custom'          // Custom date range
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
