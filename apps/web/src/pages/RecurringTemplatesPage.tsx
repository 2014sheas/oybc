import { useMemo } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import {
  validateSpawnPool,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useRecurringBoardTemplates } from '../hooks';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { RecurringTemplateRow } from '../components/recurringTemplates/RecurringTemplateRow';
import {
  computePoolPreview,
  type PoolPreview,
} from '../components/recurringTemplates/poolPreview';
import styles from './RecurringTemplatesPage.module.css';

/**
 * RecurringTemplatesPage — Profile sub-page that lists the user's
 * recurring board templates with pool preview / add-tasks / edit /
 * pause / delete affordances, plus a "+ New template" entry point.
 *
 * History: the Phase 6.2 UX rework (2026-05-08) removed creation from
 * this page ("creation flows exclusively through the board wizard" —
 * there was deliberately no "+ New template" button here). The
 * recurring-UX pass (#321) REVERSED that: hiding creation from the
 * management surface contributed to the "templates don't do anything"
 * finding, so "+ New template" is back — it routes to the same wizard
 * recurring flow as the Create hub's CTA (`/create?newRecurring=1`),
 * matching iOS's dashed "+ New template" button.
 *
 * Edit handler navigates cross-tab: `/create?editTemplate=<id>` opens
 * the Create-tab wizard hydrated from the template, in template-edit
 * mode. "Add tasks" appends `&step=tasks` to land directly on the
 * wizard's Tasks step. Same deep-link plumbing as Phase 6.1's
 * `/create?recurringTimeframe=<t>`.
 *
 * "Needs attention" badges are computed inline (same heuristic as the
 * Create-tab consumer used to do): if a `seedTaskId` fails to resolve
 * in the user's library, treat as `has_deleted_tasks` (the form
 * prevents adding non-existent IDs, so soft-delete is the only
 * realistic cause).
 */
export function RecurringTemplatesPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const templates = useRecurringBoardTemplates(user?.id);
  const library = useTaskLibrary(user?.id);

  const attentionByTemplateId = useMemo<Record<string, SpawnPoolFailureReason>>(() => {
    const out: Record<string, SpawnPoolFailureReason> = {};
    for (const t of templates) {
      const pool: typeof library.allTasks = [];
      let hasMissingFromLibrary = false;
      for (const id of t.seedTaskIds) {
        const found = library.taskMap[id];
        if (found) pool.push(found);
        else hasMissingFromLibrary = true;
      }
      if (hasMissingFromLibrary) {
        out[t.id] = 'has_deleted_tasks';
        continue;
      }
      const v = validateSpawnPool(t, pool);
      if (!v.ok) out[t.id] = v.reason;
    }
    return out;
  }, [templates, library.taskMap, library.allTasks]);

  // First few resolved pool task titles (+ resolved overflow count) per
  // template — feeds the row's compact pool preview.
  const poolPreviewByTemplateId = useMemo<Record<string, PoolPreview>>(() => {
    const out: Record<string, PoolPreview> = {};
    for (const t of templates) {
      out[t.id] = computePoolPreview(t.seedTaskIds, library.taskMap);
    }
    return out;
  }, [templates, library.taskMap]);

  const handleEdit = (template: RecurringBoardTemplate) => {
    navigate(`/create?editTemplate=${encodeURIComponent(template.id)}`);
  };

  // "Add tasks" — same edit deep link, landing on the wizard's Tasks step.
  const handleAddTasks = (template: RecurringBoardTemplate) => {
    navigate(`/create?editTemplate=${encodeURIComponent(template.id)}&step=tasks`);
  };

  // "+ New template" — the wizard's fresh recurring flow (same entry as
  // the Create hub's "Create a recurring board" CTA).
  const handleNewTemplate = () => {
    navigate('/create?newRecurring=1');
  };

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/profile" className={styles.backLink}>
          ‹ Profile
        </Link>
        <h1 className={styles.title}>Recurring templates</h1>
      </header>

      {templates.length === 0 ? (
        <div className={styles.emptyState}>
          <p className={styles.emptyTitle}>No recurring templates yet.</p>
          <p className={styles.emptyBody}>
            Create one below, or from the Create tab — tap{' '}
            <strong>"Create a recurring board"</strong>.
          </p>
        </div>
      ) : (
        <div className={styles.list}>
          {templates.map((t) => (
            <RecurringTemplateRow
              key={t.id}
              template={t}
              attentionReason={attentionByTemplateId[t.id]}
              poolPreview={poolPreviewByTemplateId[t.id]?.titles}
              poolPreviewOverflow={poolPreviewByTemplateId[t.id]?.overflow}
              onEdit={handleEdit}
              onAddTasks={handleAddTasks}
            />
          ))}
        </div>
      )}

      <button
        type="button"
        className={styles.newTemplateButton}
        onClick={handleNewTemplate}
      >
        + New template
      </button>
    </div>
  );
}
