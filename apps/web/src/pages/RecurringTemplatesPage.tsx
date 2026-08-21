import { useMemo } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import type { RecurringBoardTemplate, SpawnPoolFailureReason } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useRecurringBoardTemplates, useTemplateMixes } from '../hooks';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { RecurringTemplateRow } from '../components/recurringTemplates/RecurringTemplateRow';
import { computeTemplateAttention } from '../components/recurringTemplates/templateHealth';
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
 * finding, so "+ New template" is back. P4 (Task Pools + Recurring
 * Boards Rework) retired the dedicated `?newRecurring=1` deep link
 * (and the Create hub's separate "Create a recurring board" CTA it
 * fed) — "+ New template" now navigates plainly to `/create`, landing
 * on the unified wizard's Step 1, where the "Repeats" segmented is how
 * the user picks a cadence.
 *
 * Edit handler navigates cross-tab: `/create?editTemplate=<id>` opens
 * the Create-tab wizard hydrated from the template, in template-edit
 * mode. "Add tasks" appends `&step=tasks` to land directly on the
 * wizard's Tasks step. Same deep-link plumbing as Phase 6.1's
 * `/create?recurringTimeframe=<t>`.
 *
 * "Needs attention" badges, the pool preview chips, and the "N-task
 * pool" meta text are all computed from each template's CURRENT resolved
 * pool-mix (`useTemplateMixes`, batched once for the whole list — NOT
 * `template.seedTaskIds`, which goes stale the first time the P1
 * legacy-editor write-through edits a linked Pool; see
 * docs/POOLS_RECURRING.md §Migration "seedTaskIds end state" and
 * `computeTemplateAttention`'s docstring). The `has_deleted_tasks`
 * heuristic (an id that fails to resolve in the user's library) applies
 * to the resolved mix the same way it used to apply to `seedTaskIds`.
 */
export function RecurringTemplatesPage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const templates = useRecurringBoardTemplates(user?.id);
  const library = useTaskLibrary(user?.id);

  // Batched (one query pass for the whole page, not one per row — see
  // `useTemplateMixes`'s docstring). `undefined` while loading; each
  // row's own computation below falls back to that template's
  // `seedTaskIds` in the meantime so nothing flashes "0 tasks".
  const templateMixes = useTemplateMixes(templates);

  const attentionByTemplateId = useMemo<Record<string, SpawnPoolFailureReason>>(
    () => computeTemplateAttention(templates, templateMixes ?? {}, library.taskMap),
    [templates, templateMixes, library.taskMap],
  );

  // First few resolved pool task titles (+ resolved overflow count) per
  // template — feeds the row's compact pool preview.
  const poolPreviewByTemplateId = useMemo<Record<string, PoolPreview>>(() => {
    const out: Record<string, PoolPreview> = {};
    for (const t of templates) {
      const mixTaskIds = templateMixes?.[t.id] ?? t.seedTaskIds;
      out[t.id] = computePoolPreview(mixTaskIds, library.taskMap);
    }
    return out;
  }, [templates, templateMixes, library.taskMap]);

  // Resolved pool size for the row's "N-task pool" meta text — same
  // mix-with-seedTaskIds-fallback source as the two computations above.
  const poolSizeByTemplateId = useMemo<Record<string, number>>(() => {
    const out: Record<string, number> = {};
    for (const t of templates) {
      out[t.id] = (templateMixes?.[t.id] ?? t.seedTaskIds).length;
    }
    return out;
  }, [templates, templateMixes]);

  const handleEdit = (template: RecurringBoardTemplate) => {
    navigate(`/create?editTemplate=${encodeURIComponent(template.id)}`);
  };

  // "Add tasks" — same edit deep link, landing on the wizard's Tasks step.
  const handleAddTasks = (template: RecurringBoardTemplate) => {
    navigate(`/create?editTemplate=${encodeURIComponent(template.id)}&step=tasks`);
  };

  // "+ New template" — P4 retired the `?newRecurring=1` deep link; this
  // now navigates plainly to the Create hub, where the wizard's Step 1
  // "Repeats" segmented is how the user picks a cadence.
  const handleNewTemplate = () => {
    navigate('/create');
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
            <strong>"Start a new board"</strong> and choose a repeat cadence
            in Setup.
          </p>
        </div>
      ) : (
        <div className={styles.list}>
          {templates.map((t) => (
            <RecurringTemplateRow
              key={t.id}
              template={t}
              poolTaskCount={poolSizeByTemplateId[t.id] ?? t.seedTaskIds.length}
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
