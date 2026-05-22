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
import styles from './RecurringTemplatesPage.module.css';

/**
 * RecurringTemplatesPage — Profile sub-page that lists the user's
 * recurring board templates with edit / pause / delete affordances.
 *
 * Per the Phase 6.2 UX rework (2026-05-08), templates moved out of
 * the Create tab. Creation flows exclusively through the board wizard
 * — there's no "+ New template" button on this page. The empty-state
 * copy points the user to the wizard.
 *
 * Edit handler navigates cross-tab: `/create?editTemplate=<id>` opens
 * the Create-tab wizard hydrated from the template, in template-edit
 * mode. Same deep-link plumbing as Phase 6.1's
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

  const handleEdit = (template: RecurringBoardTemplate) => {
    navigate(`/create?editTemplate=${encodeURIComponent(template.id)}`);
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
            Create one from the Create tab — tap{' '}
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
              onEdit={handleEdit}
            />
          ))}
        </div>
      )}
    </div>
  );
}
