import {
  lateLogCompletion,
  lateLogIncrement,
  lateLogCompoundParts,
  undoLateLog,
  type LateLogCompoundAction,
} from '../db/operations/lateLog';

/** Board Edit redesign slice 4 (D15/D7) — the closed-board late-log sheet's
 *  DB-write seam, bound to one board. Thin: each method is a direct pass-
 *  through to the `db/operations/lateLog.ts` choke point, so the sheet
 *  component stays free of import churn and the write shape stays in one
 *  place. */
export interface UseLateLogResult {
  commitCompletion: (taskId: string) => Promise<void>;
  commitIncrement: (taskId: string, delta: number) => Promise<void>;
  commitCompoundParts: (compoundTaskId: string, actions: LateLogCompoundAction[]) => Promise<void>;
  undo: (taskId: string) => Promise<boolean>;
}

export function useLateLog(boardId: string): UseLateLogResult {
  return {
    commitCompletion: (taskId: string) => lateLogCompletion(boardId, taskId),
    commitIncrement: (taskId: string, delta: number) => lateLogIncrement(boardId, taskId, delta),
    commitCompoundParts: (compoundTaskId: string, actions: LateLogCompoundAction[]) =>
      lateLogCompoundParts(boardId, compoundTaskId, actions),
    undo: (taskId: string) => undoLateLog(boardId, taskId),
  };
}
