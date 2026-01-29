-- OYBC Database Schema for GRDB
-- Version: 2.0
-- Offline-first architecture with UUID primary keys

-- ===== Users Table =====

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY NOT NULL,
    email TEXT NOT NULL,
    displayName TEXT,
    photoURL TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_updated ON users(updatedAt);

-- ===== Boards Table =====

CREATE TABLE IF NOT EXISTS boards (
    id TEXT PRIMARY KEY NOT NULL,
    userId TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL, -- draft, active, completed, archived
    boardSize INTEGER NOT NULL, -- 3, 4, or 5
    timeframe TEXT NOT NULL, -- daily, weekly, monthly, yearly, custom
    startDate TEXT NOT NULL,
    endDate TEXT NOT NULL,
    centerSquareType TEXT NOT NULL, -- free, custom, none
    isRandomized INTEGER NOT NULL DEFAULT 0, -- SQLite boolean (0/1)
    totalTasks INTEGER NOT NULL DEFAULT 0,
    completedTasks INTEGER NOT NULL DEFAULT 0,
    linesCompleted INTEGER NOT NULL DEFAULT 0,
    completedLineIds TEXT, -- JSON array: ["row_0", "col_1", "diag_0"]
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    completedAt TEXT,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0, -- SQLite boolean
    deletedAt TEXT,
    FOREIGN KEY (userId) REFERENCES users(id)
);

-- Board indexes
CREATE INDEX idx_boards_user_deleted ON boards(userId, isDeleted);
CREATE INDEX idx_boards_user_timeframe_status ON boards(userId, timeframe, status);
CREATE INDEX idx_boards_user_timeframe_lines ON boards(userId, timeframe, linesCompleted);
CREATE INDEX idx_boards_updated ON boards(updatedAt);
CREATE INDEX idx_boards_status ON boards(status);

-- ===== Tasks Table =====

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY NOT NULL,
    userId TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    type TEXT NOT NULL, -- normal, counting, progress
    action TEXT,
    unit TEXT,
    maxCount INTEGER,
    parentStepId TEXT, -- References task_steps.id
    parentStepIndex INTEGER,
    progressCounters TEXT, -- JSON array of TaskProgressCounter objects
    totalCompletions INTEGER NOT NULL DEFAULT 0,
    totalInstances INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,
    FOREIGN KEY (userId) REFERENCES users(id),
    FOREIGN KEY (parentStepId) REFERENCES task_steps(id)
);

-- Task indexes
CREATE INDEX idx_tasks_user_deleted ON tasks(userId, isDeleted);
CREATE INDEX idx_tasks_updated ON tasks(updatedAt);
CREATE INDEX idx_tasks_type ON tasks(type);
CREATE INDEX idx_tasks_parent_step ON tasks(parentStepId);

-- ===== TaskSteps Table =====

CREATE TABLE IF NOT EXISTS task_steps (
    id TEXT PRIMARY KEY NOT NULL,
    taskId TEXT NOT NULL,
    stepIndex INTEGER NOT NULL,
    title TEXT NOT NULL,
    type TEXT NOT NULL, -- normal or counting
    action TEXT,
    unit TEXT,
    maxCount INTEGER,
    linkedTaskId TEXT, -- References tasks.id
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,
    FOREIGN KEY (taskId) REFERENCES tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (linkedTaskId) REFERENCES tasks(id)
);

-- TaskStep indexes
CREATE INDEX idx_task_steps_task_index ON task_steps(taskId, stepIndex);
CREATE INDEX idx_task_steps_linked ON task_steps(linkedTaskId);
CREATE INDEX idx_task_steps_deleted_task ON task_steps(isDeleted, taskId);

-- ===== BoardTasks Junction Table =====

CREATE TABLE IF NOT EXISTS board_tasks (
    id TEXT PRIMARY KEY NOT NULL,
    boardId TEXT NOT NULL,
    taskId TEXT NOT NULL,
    row INTEGER NOT NULL,
    col INTEGER NOT NULL,
    isCenter INTEGER NOT NULL DEFAULT 0,
    isCompleted INTEGER NOT NULL DEFAULT 0,
    completedAt TEXT,
    currentCount INTEGER,
    completedStepIds TEXT, -- JSON array of TaskStep IDs
    isAchievementSquare INTEGER DEFAULT 0,
    achievementType TEXT, -- bingo or full_completion
    achievementCount INTEGER,
    achievementTimeframe TEXT, -- daily, weekly, monthly, yearly
    achievementProgress INTEGER,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY (boardId) REFERENCES boards(id) ON DELETE CASCADE,
    FOREIGN KEY (taskId) REFERENCES tasks(id)
);

-- BoardTask indexes
CREATE INDEX idx_board_tasks_board_completed ON board_tasks(boardId, isCompleted);
CREATE INDEX idx_board_tasks_board ON board_tasks(boardId);
CREATE INDEX idx_board_tasks_task ON board_tasks(taskId);
CREATE INDEX idx_board_tasks_achievement ON board_tasks(isAchievementSquare);
CREATE INDEX idx_board_tasks_achievement_timeframe ON board_tasks(isAchievementSquare, achievementTimeframe);

-- ===== ProgressCounters Table =====

CREATE TABLE IF NOT EXISTS progress_counters (
    id TEXT PRIMARY KEY NOT NULL,
    userId TEXT NOT NULL,
    name TEXT NOT NULL,
    unit TEXT NOT NULL,
    targetValue REAL NOT NULL,
    currentValue REAL NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,
    FOREIGN KEY (userId) REFERENCES users(id)
);

-- ProgressCounter indexes
CREATE INDEX idx_progress_counters_user_deleted ON progress_counters(userId, isDeleted);
CREATE INDEX idx_progress_counters_updated ON progress_counters(updatedAt);

-- ===== SyncQueue Table =====

CREATE TABLE IF NOT EXISTS sync_queue (
    id TEXT PRIMARY KEY NOT NULL,
    entityType TEXT NOT NULL,
    entityId TEXT NOT NULL,
    operationType TEXT NOT NULL, -- create, update, delete
    payload TEXT NOT NULL, -- JSON string
    status TEXT NOT NULL, -- pending, in_progress, completed, failed
    retryCount INTEGER NOT NULL DEFAULT 0,
    lastError TEXT,
    createdAt TEXT NOT NULL,
    lastAttemptAt TEXT,
    completedAt TEXT,
    priority INTEGER NOT NULL DEFAULT 0
);

-- SyncQueue indexes
CREATE INDEX idx_sync_queue_status_priority ON sync_queue(status, priority, createdAt);
CREATE INDEX idx_sync_queue_entity ON sync_queue(entityType, entityId);

-- ===== Schema Version Tracking =====

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY NOT NULL,
    appliedAt TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_version (version, appliedAt) VALUES (1, datetime('now'));
