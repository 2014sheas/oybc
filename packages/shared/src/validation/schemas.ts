import { z } from 'zod';
import { BoardStatus, TaskType, Timeframe, CenterSquareType, SyncOperationType, SyncStatus } from '../constants/enums';

/**
 * Validation schemas using Zod
 *
 * These schemas validate user input and ensure data integrity
 * before saving to local database or syncing to Firestore
 */

// ===== Board Schemas =====

export const BoardSizeSchema = z.union([z.literal(3), z.literal(4), z.literal(5)]);

export const CreateBoardInputSchema = z.object({
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  boardSize: BoardSizeSchema,
  timeframe: z.nativeEnum(Timeframe),
  startDate: z.string().datetime(),
  endDate: z.string().datetime(),
  centerSquareType: z.nativeEnum(CenterSquareType),
  isRandomized: z.boolean(),
}).refine(
  (data) => new Date(data.endDate) > new Date(data.startDate),
  { message: 'End date must be after start date' }
);

export const UpdateBoardInputSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  description: z.string().max(500).optional(),
  status: z.nativeEnum(BoardStatus).optional(),
});

export const BoardSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  status: z.nativeEnum(BoardStatus),
  boardSize: BoardSizeSchema,
  timeframe: z.nativeEnum(Timeframe),
  startDate: z.string().datetime(),
  endDate: z.string().datetime(),
  centerSquareType: z.nativeEnum(CenterSquareType),
  isRandomized: z.boolean(),
  totalTasks: z.number().int().min(0),
  completedTasks: z.number().int().min(0),
  linesCompleted: z.number().int().min(0),
  completedLineIds: z.array(z.string()).optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  completedAt: z.string().datetime().optional(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== Task Schemas =====

export const CreateTaskStepInputSchema = z.object({
  title: z.string().min(1).max(200),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
});

export const CreateTaskInputSchema = z.object({
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  steps: z.array(CreateTaskStepInputSchema).optional(),
}).refine(
  (data) => {
    // Counting tasks must have action, unit, and maxCount
    if (data.type === TaskType.COUNTING) {
      return data.action && data.unit && data.maxCount;
    }
    return true;
  },
  { message: 'Counting tasks must have action, unit, and maxCount' }
).refine(
  (data) => {
    // Progress tasks must have steps
    if (data.type === TaskType.PROGRESS) {
      return data.steps && data.steps.length > 0;
    }
    return true;
  },
  { message: 'Progress tasks must have at least one step' }
);

export const UpdateTaskInputSchema = z.object({
  title: z.string().min(1).max(200).optional(),
  description: z.string().max(1000).optional(),
});

export const TaskProgressCounterSchema = z.object({
  counterId: z.string().uuid(),
  targetValue: z.number().positive(),
  unit: z.string().max(50).optional(),
});

export const TaskSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  parentStepId: z.string().uuid().optional(),
  parentStepIndex: z.number().int().min(0).optional(),
  progressCounters: z.array(TaskProgressCounterSchema).optional(),
  totalCompletions: z.number().int().min(0),
  totalInstances: z.number().int().min(0),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

export const TaskStepSchema = z.object({
  id: z.string().uuid(),
  taskId: z.string().uuid(),
  stepIndex: z.number().int().min(0),
  title: z.string().min(1).max(200),
  type: z.nativeEnum(TaskType),
  action: z.string().max(50).optional(),
  unit: z.string().max(50).optional(),
  maxCount: z.number().int().positive().optional(),
  linkedTaskId: z.string().uuid().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== BoardTask Schemas =====

export const CreateBoardTaskInputSchema = z.object({
  boardId: z.string().uuid(),
  taskId: z.string().uuid(),
  row: z.number().int().min(0),
  col: z.number().int().min(0),
  isCenter: z.boolean(),
  isAchievementSquare: z.boolean().optional(),
  achievementType: z.enum(['bingo', 'full_completion']).optional(),
  achievementCount: z.number().int().positive().optional(),
  achievementTimeframe: z.nativeEnum(Timeframe).optional(),
});

export const UpdateBoardTaskCompletionInputSchema = z.object({
  isCompleted: z.boolean(),
  currentCount: z.number().int().min(0).optional(),
  completedStepIds: z.array(z.string().uuid()).optional(),
  achievementProgress: z.number().int().min(0).optional(),
});

export const BoardTaskSchema = z.object({
  id: z.string().uuid(),
  boardId: z.string().uuid(),
  taskId: z.string().uuid(),
  row: z.number().int().min(0),
  col: z.number().int().min(0),
  isCenter: z.boolean(),
  isCompleted: z.boolean(),
  completedAt: z.string().datetime().optional(),
  currentCount: z.number().int().min(0).optional(),
  completedStepIds: z.array(z.string().uuid()).optional(),
  isAchievementSquare: z.boolean().optional(),
  achievementType: z.enum(['bingo', 'full_completion']).optional(),
  achievementCount: z.number().int().positive().optional(),
  achievementTimeframe: z.nativeEnum(Timeframe).optional(),
  achievementProgress: z.number().int().min(0).optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
});

// ===== ProgressCounter Schemas =====

export const CreateProgressCounterInputSchema = z.object({
  name: z.string().min(1).max(100),
  unit: z.string().min(1).max(50),
  targetValue: z.number().positive(),
});

export const UpdateProgressCounterInputSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  currentValue: z.number().min(0).optional(),
  targetValue: z.number().positive().optional(),
});

export const ProgressCounterSchema = z.object({
  id: z.string().uuid(),
  userId: z.string(),
  name: z.string().min(1).max(100),
  unit: z.string().min(1).max(50),
  targetValue: z.number().positive(),
  currentValue: z.number().min(0),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
  isDeleted: z.boolean(),
  deletedAt: z.string().datetime().optional(),
});

// ===== SyncQueue Schemas =====

export const CreateSyncQueueItemInputSchema = z.object({
  entityType: z.string(),
  entityId: z.string().uuid(),
  operationType: z.nativeEnum(SyncOperationType),
  payload: z.any(),
  priority: z.number().int().optional(),
});

export const SyncQueueItemSchema = z.object({
  id: z.string().uuid(),
  entityType: z.string(),
  entityId: z.string().uuid(),
  operationType: z.nativeEnum(SyncOperationType),
  payload: z.string(), // JSON string
  status: z.nativeEnum(SyncStatus),
  retryCount: z.number().int().min(0),
  lastError: z.string().optional(),
  createdAt: z.string().datetime(),
  lastAttemptAt: z.string().datetime().optional(),
  completedAt: z.string().datetime().optional(),
  priority: z.number().int(),
});

// ===== User Schema =====

export const UserSchema = z.object({
  id: z.string(),
  email: z.string().email(),
  displayName: z.string().optional(),
  photoURL: z.string().url().optional(),
  createdAt: z.string().datetime(),
  updatedAt: z.string().datetime(),
  lastSyncedAt: z.string().datetime().optional(),
  version: z.number().int().min(1),
});
