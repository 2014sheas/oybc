import { useState, useCallback } from 'react';
import type { PoolEntry } from '../../components/BoardCreatorPanel';

/**
 * Owns the board-task-pool state for the Create page: the ordered list
 * of tasks queued for board creation plus add/remove/membership helpers.
 *
 * Duplicate adds are silently ignored (by `taskId`) so rapid clicks on
 * "Add to Pool" don't produce duplicate rows. Membership is O(n); the
 * pool is small in practice (≤25 for a 5×5 board) so no index needed.
 *
 * Extracted from CreatePage to keep the container thin.
 */
export interface BoardPool {
  pool: PoolEntry[];
  addToPool: (entry: PoolEntry) => void;
  removeFromPool: (taskId: string) => void;
  isInPool: (taskId: string) => boolean;
  clearPool: () => void;
}

export function useBoardPool(): BoardPool {
  const [pool, setPool] = useState<PoolEntry[]>([]);

  const addToPool = useCallback((entry: PoolEntry) => {
    setPool((prev) => {
      if (prev.some((e) => e.taskId === entry.taskId)) return prev;
      return [...prev, entry];
    });
  }, []);

  const removeFromPool = useCallback((taskId: string) => {
    setPool((prev) => prev.filter((e) => e.taskId !== taskId));
  }, []);

  const isInPool = useCallback(
    (taskId: string) => pool.some((e) => e.taskId === taskId),
    [pool]
  );

  const clearPool = useCallback(() => {
    setPool([]);
  }, []);

  return { pool, addToPool, removeFromPool, isInPool, clearPool };
}
