import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import { fetchTask } from '../db/operations';
import { TaskDetailContent } from './tasks/TaskDetailContent';
import pageStyles from './TaskDetailPage.module.css';

/**
 * TaskDetailPage — thin route wrapper for the task detail surface.
 *
 * Owns:
 *   - `useParams` resolution (`:id`)
 *   - One-shot 404 detection (`'pending' | 'present' | 'missing'` state)
 *   - Redirect on deletion / soft-delete while viewing
 *
 * All content is delegated to `<TaskDetailContent>`, which can also be
 * mounted as a sheet over other surfaces (e.g., BoardPlayPage).
 *
 * Route-mode: `onClose` is NOT passed to `TaskDetailContent`, so the
 * content component skips its own back affordance. The route back link
 * is rendered here in a small header row above the content.
 */
export function TaskDetailPage(): React.ReactElement {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const task = useLiveQuery(
    async () => (id ? fetchTask(id) : undefined),
    [id],
  );

  // `useLiveQuery` returns `undefined` for both "still loading" AND
  // "no row matches" — we can't distinguish 404 from loading by
  // inspecting it alone. A parallel one-shot `get(id)` lets us settle
  // the question: once it resolves to `undefined`, the row is missing.
  const [resolved, setResolved] = useState<'pending' | 'present' | 'missing'>(
    'pending',
  );
  useEffect(() => {
    if (!id) {
      setResolved('missing');
      return;
    }
    setResolved('pending');
    let cancelled = false;
    void (async () => {
      const row = await fetchTask(id);
      if (cancelled) return;
      setResolved(row === undefined ? 'missing' : 'present');
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  // Redirect on (a) bogus id, (b) task soft-deleted while viewing.
  useEffect(() => {
    if (resolved === 'missing') {
      navigate('/tasks', { replace: true });
      return;
    }
    if (task && task.isDeleted) {
      navigate('/tasks', { replace: true });
    }
  }, [resolved, task, navigate]);

  if (!id) {
    return (
      <div className={pageStyles.shell}>
        <p className={pageStyles.loading}>Task not found.</p>
        <Link to="/tasks" className={pageStyles.back}>‹ Tasks</Link>
      </div>
    );
  }
  if (resolved === 'pending' || resolved === 'missing') {
    return (
      <div className={pageStyles.shell}>
        <p className={pageStyles.loading}>Loading…</p>
      </div>
    );
  }
  if (!task || task.isDeleted) {
    return (
      <div className={pageStyles.shell}>
        <p className={pageStyles.loading}>Loading…</p>
      </div>
    );
  }

  return (
    <div className={pageStyles.shell}>
      <header className={pageStyles.header}>
        <Link to="/tasks" className={pageStyles.back}>
          ‹ Tasks
        </Link>
      </header>
      <TaskDetailContent
        task={task}
        onChanged={() => {}}
        onClose={() => navigate('/tasks')}
        onOpenTask={(taskId) => { navigate(`/tasks/${taskId}`); }}
      />
    </div>
  );
}
