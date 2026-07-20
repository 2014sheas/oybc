import { formatPoolShortSummary } from '@oybc/shared';
import type { Pool, PoolHealthResult, Task } from '@oybc/shared';
import { RisoCard } from '../riso';
import styles from './PoolCard.module.css';

/** First-N task-title chips shown on a pool card before "+N more". */
const CHIP_LIMIT = 4;

export interface PoolCardProps {
  pool: Pool;
  /** Resolvable non-deleted tasks, in `pool.taskIds` order, for the chip
   *  row + count. Resolved once at the page level (batched), not here. */
  tasks: Task[];
  /** This pool's derived health (P2 Task 1's `computePoolHealth`), passed
   *  in from the page's batched pass — never computed per-card. Rendered
   *  as a single combined board-count line via `formatPoolShortSummary`
   *  (owner decision, 2026-07-20) — no per-consumer detail. */
  health: PoolHealthResult;
  onClick: (pool: Pool) => void;
}

/**
 * PoolCard — one row on the Tasks-tab Pools browse (P2). Mirrors the iOS
 * `DefaultPoolsListView.poolCard` visual language minus the "FEEDS" tag
 * (pools are no longer timeframe-keyed) — see docs/POOLS_RECURRING.md
 * §Surfaces item 1 + the handoff screenshot `01-pools.png`.
 *
 * NO board-related actions render here (locked decision) — the whole
 * card is a single tap target that opens the edit sheet.
 */
export function PoolCard({ pool, tasks, health, onClick }: PoolCardProps): React.ReactElement {
  const visible = tasks.slice(0, CHIP_LIMIT);
  const overflow = tasks.length - visible.length;
  const taskCount = health.taskCount;
  const shortSummary = formatPoolShortSummary(health.consumers);

  return (
    <RisoCard
      shadow="small"
      padded
      interactive
      className={styles.card}
      role="button"
      tabIndex={0}
      onClick={() => onClick(pool)}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onClick(pool);
        }
      }}
      aria-label={`Edit pool ${pool.name}`}
    >
      <div className={styles.name}>{pool.name}</div>

      {visible.length > 0 && (
        <div className={styles.chips}>
          {visible.map((task) => (
            <span key={task.id} className={styles.chip}>
              {task.title || '(untitled task)'}
            </span>
          ))}
          {overflow > 0 && <span className={styles.moreChip}>+{overflow} more</span>}
        </div>
      )}

      <div className={styles.meta}>
        <strong>{taskCount}</strong> task{taskCount === 1 ? '' : 's'} · tap to edit
      </div>

      {shortSummary !== '' && (
        <div className={styles.warning} role="status">
          {shortSummary}
        </div>
      )}
    </RisoCard>
  );
}
