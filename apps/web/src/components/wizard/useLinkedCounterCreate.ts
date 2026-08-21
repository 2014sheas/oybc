import { useCallback } from 'react';
import { TaskType, type Task, type Timeframe } from '@oybc/shared';
import { createTask } from '../../db/operations/tasks';
import { generateUUID, currentTimestamp } from '../../db/utils';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { type LinkedCounterInput } from './CountingTemplatePicker';

export interface UseLinkedCounterCreateArgs {
  /** Authenticated user id. */
  userId: string;
  /** Board timeframe/dates inherited by the new task — same contract as
   *  `useCreateFormState`'s `defaultTimeframe`/`defaultStartDate`/`defaultEndDate`. */
  defaultTimeframe?: Timeframe;
  defaultStartDate?: string;
  defaultEndDate?: string;
  /** Fired with the created (or in-memory pending) task. */
  onTaskCreated: (task: Task) => void;
  /** Bug #85 — deferred-persist callback. Presence implies deferred mode,
   *  matching every other creation surface's convention. */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /** Fired after a successful create (persisted or deferred) — the host
   *  closes its sheet / collapses its panel here. */
  onCreated: () => void;
}

/**
 * R1 counters refresh — shared "auto-link to an existing counter" creation
 * path, extracted from `NewTaskSheet`'s `handleCreateLinked` (Web inline-
 * editing port PR-1) so `SpecialTaskPanel` (the wizard Tasks step's inline
 * special-type panel) can offer the exact same "Don't link" / linked-create
 * behavior as the modal `NewTaskSheet` without a second, divergent copy.
 *
 * `CreateNewTaskForm` calls the returned function instead of
 * `form.handleSubmit` when a counting-task submit's (verb, noun) pair
 * exactly matches an existing counter and the user hasn't opted out via
 * `CounterLinkHint`'s "Don't link" pill. Creates a new COUNTING task with
 * `sharedCounterId` + `baseline` set (always "start fresh"), then notifies
 * the caller. Respects the same deferred-persist path as a regular
 * COUNTING create so wizard usage stays atomic.
 */
export function useLinkedCounterCreate({
  userId,
  defaultTimeframe,
  defaultStartDate,
  defaultEndDate,
  onTaskCreated,
  onPendingCreated,
  onCreated,
}: UseLinkedCounterCreateArgs): (input: LinkedCounterInput) => Promise<void> {
  return useCallback(
    async (input: LinkedCounterInput): Promise<void> => {
      if (!userId) return;
      const deferPersist = onPendingCreated !== undefined;
      try {
        let newTask: Task;
        if (deferPersist) {
          // Build in-memory for the wizard — written inside the board-save txn.
          const now = currentTimestamp();
          newTask = {
            id: generateUUID(),
            userId,
            title: input.title,
            type: TaskType.COUNTING,
            action: input.source.action ?? '',
            unit: input.source.unit ?? '',
            maxCount: input.maxCount,
            currentCount: 0,
            sharedCounterId: input.source.id,
            baseline: input.baseline,
            isCompleted: false,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate,
            // Wizard-born — hidden from the task library until the board goes active.
            createdInWizard: true,
          };
          onPendingCreated?.({ task: newTask, childTasks: [], childLinks: [] });
        } else {
          // Immediate-persist path (Tasks-tab standalone quick-add).
          newTask = await createTask(userId, {
            title: input.title,
            type: TaskType.COUNTING,
            action: input.source.action ?? '',
            unit: input.source.unit ?? '',
            maxCount: input.maxCount,
            sharedCounterId: input.source.id,
            baseline: input.baseline,
            timeframe: defaultTimeframe,
            startDate: defaultStartDate,
            endDate: defaultEndDate,
          });
        }
        onTaskCreated(newTask);
        onCreated();
      } catch (err) {
        // Surface to the console; neither host has a dedicated error banner
        // for the link path. A future iteration can thread an error state.
        console.error('[useLinkedCounterCreate] create failed:', err);
      }
    },
    [
      userId,
      onPendingCreated,
      onTaskCreated,
      onCreated,
      defaultTimeframe,
      defaultStartDate,
      defaultEndDate,
    ],
  );
}
