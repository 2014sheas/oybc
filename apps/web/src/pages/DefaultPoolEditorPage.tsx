import { useEffect, useMemo, useState } from 'react';
import { Link, Navigate, useNavigate, useParams } from 'react-router-dom';
import { Timeframe, TaskType, type Task } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useDefaultPool } from '../hooks';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { upsertDefaultPool, softDeleteDefaultPool } from '../db/operations/defaultPools';
import { TypeBadge } from '../components/TypeBadge';
import styles from './DefaultPoolEditorPage.module.css';

const VALID_TIMEFRAMES = new Set<string>([
  Timeframe.DAILY,
  Timeframe.WEEKLY,
  Timeframe.MONTHLY,
  Timeframe.YEARLY,
]);

const TIMEFRAME_LABEL: Record<string, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
};

/**
 * DefaultPoolEditorPage — /profile/default-pools/:timeframe
 *
 * Task picker for a single timeframe's pool. On mount, hydrates the
 * existing pool's `taskIds` into a local Set; the user toggles tasks
 * in/out and Save persists via `upsertDefaultPool`. Cancel returns to
 * the list without saving.
 *
 * "Clear pool" is a destructive option: soft-deletes the DefaultPool
 * row entirely so the index page shows "Not set" again. Distinct from
 * saving an empty selection (which keeps the row with `taskIds: []`).
 */
export function DefaultPoolEditorPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const { timeframe: rawTimeframe } = useParams<{ timeframe: string }>();

  // Guard: reject unknown / CUSTOM timeframes. Redirect to the list.
  if (!rawTimeframe || !VALID_TIMEFRAMES.has(rawTimeframe)) {
    return <Navigate to="/profile/default-pools" replace />;
  }
  const timeframe = rawTimeframe as Timeframe;

  const library = useTaskLibrary(user?.id);
  const pool = useDefaultPool(user?.id, timeframe);

  // Local selection state — initialized from the pool, but the pool may
  // arrive asynchronously (useLiveQuery is `undefined` on first frame).
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    if (!hydrated && pool !== undefined) {
      // pool may be undefined permanently (no pool yet) — useLiveQuery
      // returns undefined for both "loading" and "no row". Treat the
      // first observed value as the hydration signal; the no-pool case
      // resolves with `pool === undefined` after a microtask, and
      // hydration just leaves `selectedIds` empty.
      setSelectedIds(new Set(pool?.taskIds ?? []));
      setHydrated(true);
    }
  }, [pool, hydrated]);

  // All non-deleted, non-achievement tasks are pickable. Achievements
  // (Phase 6.3) reference boards/templates and don't make sense in a
  // default pool — exclude.
  const pickableTasks: Task[] = useMemo(
    () => library.allTasks.filter((t) => t.type !== TaskType.ACHIEVEMENT),
    [library.allTasks],
  );

  const [search, setSearch] = useState('');
  const visibleTasks = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return pickableTasks;
    return pickableTasks.filter(
      (t) =>
        t.title.toLowerCase().includes(q) ||
        (t.description?.toLowerCase().includes(q) ?? false),
    );
  }, [pickableTasks, search]);

  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleToggle = (taskId: string): void => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(taskId)) next.delete(taskId);
      else next.add(taskId);
      return next;
    });
  };

  const handleSave = async (): Promise<void> => {
    if (!user?.id) return;
    setSaving(true);
    setError(null);
    try {
      await upsertDefaultPool(user.id, timeframe, Array.from(selectedIds));
      navigate('/profile/default-pools');
    } catch (e) {
      setError(`Failed to save: ${(e as Error).message}`);
    } finally {
      setSaving(false);
    }
  };

  const handleClearPool = async (): Promise<void> => {
    if (!pool) return;
    if (!window.confirm(`Clear the ${TIMEFRAME_LABEL[timeframe]} default pool?`)) {
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await softDeleteDefaultPool(pool.id);
      navigate('/profile/default-pools');
    } catch (e) {
      setError(`Failed to clear: ${(e as Error).message}`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/profile/default-pools" className={styles.backLink}>
          ‹ Default pools
        </Link>
        <h1 className={styles.title}>
          {TIMEFRAME_LABEL[timeframe]} pool
        </h1>
        <p className={styles.subtitle}>
          {selectedIds.size} task{selectedIds.size === 1 ? '' : 's'} selected
        </p>
      </header>

      <input
        type="search"
        className={styles.search}
        placeholder="Search tasks…"
        value={search}
        onChange={(e) => setSearch(e.target.value)}
      />

      {visibleTasks.length === 0 ? (
        <div className={styles.emptyState}>
          {pickableTasks.length === 0
            ? 'No tasks in your library yet. Create some from the Tasks tab.'
            : `No tasks match "${search}".`}
        </div>
      ) : (
        <ul className={styles.list}>
          {visibleTasks.map((task) => {
            const checked = selectedIds.has(task.id);
            return (
              <li key={task.id}>
                <button
                  type="button"
                  className={`${styles.row} ${checked ? styles.rowSelected : ''}`}
                  onClick={() => handleToggle(task.id)}
                  aria-pressed={checked}
                >
                  <span className={styles.check}>{checked ? '✓' : ''}</span>
                  <TypeBadge type={task.type} size="small" letterOnly />
                  <span className={styles.rowTitle}>{task.title}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}

      {error && <p className={styles.error}>{error}</p>}

      <footer className={styles.actions}>
        {pool && (
          <button
            type="button"
            className={styles.clearButton}
            onClick={handleClearPool}
            disabled={saving}
          >
            Clear pool
          </button>
        )}
        <button
          type="button"
          className={styles.cancelButton}
          onClick={() => navigate('/profile/default-pools')}
          disabled={saving}
        >
          Cancel
        </button>
        <button
          type="button"
          className={styles.saveButton}
          onClick={handleSave}
          disabled={saving}
        >
          {saving ? 'Saving…' : 'Save'}
        </button>
      </footer>
    </div>
  );
}
