import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { Timeframe, type DefaultPool } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useDefaultPools } from '../hooks';
import styles from './DefaultPoolsListPage.module.css';

/**
 * DefaultPoolsListPage — Profile sub-page (/profile/default-pools)
 *
 * Lists the four recurring timeframes (Daily / Weekly / Monthly / Yearly)
 * with a per-row summary of the pool's task count + Edit link. Tapping
 * a row opens `/profile/default-pools/:timeframe` where the user picks
 * tasks from their library.
 *
 * A pool's `taskIds` may be empty (set up then cleared) — that's
 * distinct from "no pool set up yet". The summary text below
 * disambiguates: "Not set" (no DefaultPool row exists) vs "0 tasks"
 * (row exists, taskIds empty).
 */
const POOL_TIMEFRAMES: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

export function DefaultPoolsListPage(): React.ReactElement {
  const { user } = useAuth();
  const pools = useDefaultPools(user?.id);

  const poolByTimeframe = useMemo(() => {
    const out: Partial<Record<Timeframe, DefaultPool>> = {};
    for (const p of pools) out[p.timeframe] = p;
    return out;
  }, [pools]);

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/profile" className={styles.backLink}>
          ‹ Profile
        </Link>
        <h1 className={styles.title}>Default pools</h1>
      </header>

      <p className={styles.body}>
        A default pool prefills the recurring-banner wizard with the same
        tasks every time you create a core board for that timeframe. You can
        still add or remove tasks before saving.
      </p>

      <div className={styles.card}>
        {POOL_TIMEFRAMES.map(({ value, label }) => {
          const pool = poolByTimeframe[value];
          const summary = pool
            ? `${pool.taskIds.length} task${pool.taskIds.length === 1 ? '' : 's'}`
            : 'Not set';
          return (
            <Link
              key={value}
              to={`/profile/default-pools/${value}`}
              className={styles.row}
            >
              <span className={styles.rowLabel}>{label}</span>
              <span className={styles.rowSummary}>{summary}</span>
              <span className={styles.rowArrow}>&rarr;</span>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
