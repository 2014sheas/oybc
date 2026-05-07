import { useState } from 'react';
import type {
  RecurringBoardTemplate,
  SpawnPoolFailureReason,
  Task,
} from '@oybc/shared';
import { RecurringTemplateRow } from './RecurringTemplateRow';
import { RecurringTemplateForm } from './RecurringTemplateForm';
import styles from './RecurringTemplatesSection.module.css';

/**
 * RecurringTemplatesSection — Phase 6.2 surface on the Create tab.
 *
 * Mounted between drafts and the library section. Owns the edit/create
 * form state; clicking a row's Edit button or the "+ New template"
 * button opens the modal form.
 *
 * Renders nothing (returns the empty-state shell only) when the user
 * has no templates AND no incoming attention items — the heading is
 * still shown so the section is discoverable when empty.
 */
export interface RecurringTemplatesSectionProps {
  userId: string;
  templates: RecurringBoardTemplate[];
  libraryTasks: Task[];
  attentionByTemplateId: Record<string, SpawnPoolFailureReason | 'no_pool_tasks_resolved'>;
}

export function RecurringTemplatesSection({
  userId,
  templates,
  libraryTasks,
  attentionByTemplateId,
}: RecurringTemplatesSectionProps): React.ReactElement {
  const [editing, setEditing] = useState<RecurringBoardTemplate | null>(null);
  const [creating, setCreating] = useState(false);

  return (
    <section className={styles.section}>
      <header className={styles.heading}>
        <h3 className={styles.headingText}>Recurring templates</h3>
        <button
          type="button"
          className={styles.newButton}
          onClick={() => setCreating(true)}
        >
          + New template
        </button>
      </header>

      {templates.length === 0 ? (
        <p className={styles.emptyState}>
          Set up a recurring template to auto-generate boards each day,
          week, month, or year.
        </p>
      ) : (
        <div className={styles.list}>
          {templates.map((t) => (
            <RecurringTemplateRow
              key={t.id}
              template={t}
              attentionReason={attentionByTemplateId[t.id]}
              onEdit={setEditing}
            />
          ))}
        </div>
      )}

      {(creating || editing !== null) && (
        <RecurringTemplateForm
          userId={userId}
          libraryTasks={libraryTasks}
          template={editing ?? undefined}
          onClose={() => {
            setCreating(false);
            setEditing(null);
          }}
        />
      )}
    </section>
  );
}
