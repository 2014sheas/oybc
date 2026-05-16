import { OperatorType, type Task } from '@oybc/shared';
import type { SubtaskDraft } from './compositeSubtaskDraft';
import styles from './ReviewStep.module.css';

export interface ReviewStepProps {
  title: string;
  operator: OperatorType;
  threshold: number;
  subtasks: SubtaskDraft[];
  /** Library tasks + composites — needed to resolve existing-mode chips
   *  to their actual titles and metadata. */
  allTasks: Task[];
  allCompositeTasks: Task[];
  isSubmitting: boolean;
  errorMessage: string | null;
  onBack: () => void;
  onCreate: () => void;
  /** Open an existing-mode subtask's library detail. Inline-mode chips
   *  are ignored (those tasks aren't saved yet). */
  onOpenTask?: (taskId: string) => void;
}

/**
 * Step 3 — final review + commit. Shows a summary of what will be
 * written, a chip list of every subtask (so the user catches mistakes
 * before they land in the DB), and an explicit "these inline tasks
 * will also appear in your library" callout.
 *
 * Errors surface inline with a Try again affordance that re-runs the
 * transaction rather than forcing a full round-trip through Back.
 */
export function ReviewStep({
  title,
  operator,
  threshold,
  subtasks,
  allTasks,
  allCompositeTasks,
  isSubmitting,
  errorMessage,
  onBack,
  onCreate,
  onOpenTask,
}: ReviewStepProps): React.ReactElement {
  const inlineCount = subtasks.filter((s) => s.mode === 'inline').length;

  const operatorLabel =
    operator === OperatorType.AND
      ? 'All of'
      : operator === OperatorType.OR
        ? 'Any of'
        : `At least ${threshold} of`;

  return (
    <div className={styles.container}>
      <h3 className={styles.heading}>Ready to create</h3>

      <dl className={styles.summary}>
        <div className={styles.row}>
          <dt>Title</dt>
          <dd>{title.trim() || <span className={styles.placeholder}>(unset)</span>}</dd>
        </div>
        <div className={styles.row}>
          <dt>Completion rule</dt>
          <dd>
            {operatorLabel}
            <span className={styles.rowHint}> · {subtasks.length} subtask{subtasks.length === 1 ? '' : 's'}</span>
          </dd>
        </div>
      </dl>

      <div className={styles.chipSection}>
        <span className={styles.chipSectionHeading}>Subtasks</span>
        <ul className={styles.chipList}>
          {subtasks.map((s, idx) => (
            <li key={s.id}>
              <SubtaskReviewChip
                draft={s}
                allTasks={allTasks}
                allCompositeTasks={allCompositeTasks}
                index={idx + 1}
                onOpenTask={onOpenTask}
              />
            </li>
          ))}
        </ul>
      </div>

      {inlineCount > 0 && (
        <div className={styles.libraryCallout}>
          <span className={styles.libraryCalloutIcon} aria-hidden="true">📎</span>
          <span>
            {inlineCount} inline task{inlineCount === 1 ? '' : 's'} will also be saved to your library.
          </span>
        </div>
      )}

      {errorMessage !== null && (
        <div className={styles.errorBanner} role="alert">
          <span className={styles.errorBannerMessage}>{errorMessage}</span>
          <button
            type="button"
            className={styles.retryButton}
            onClick={onCreate}
            disabled={isSubmitting}
          >
            Try again
          </button>
        </div>
      )}

      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack} disabled={isSubmitting}>
          ‹ Back
        </button>
        <button
          type="button"
          className={styles.createButton}
          onClick={onCreate}
          disabled={isSubmitting}
        >
          {isSubmitting && <span className={styles.spinner} aria-hidden="true" />}
          {isSubmitting ? 'Creating…' : 'Create Composite'}
        </button>
      </div>
    </div>
  );
}

// ─── Review chip ─────────────────────────────────────────────────────────────

interface SubtaskReviewChipProps {
  draft: SubtaskDraft;
  allTasks: Task[];
  allCompositeTasks: Task[];
  index: number;
  onOpenTask?: (taskId: string) => void;
}

function SubtaskReviewChip({
  draft,
  allTasks,
  allCompositeTasks,
  index,
  onOpenTask,
}: SubtaskReviewChipProps): React.ReactElement {
  if (draft.mode === 'existing') {
    const onClick = onOpenTask ? () => onOpenTask(draft.selectedId) : undefined;
    if (draft.selectionType === 'task') {
      const task = allTasks.find((t) => t.id === draft.selectedId);
      return (
        <ReviewChipBody
          index={index}
          badge={(task?.type ?? 'task').toUpperCase()}
          title={task?.title ?? '(unknown task)'}
          meta={null}
          tone="library"
          onClick={onClick}
        />
      );
    }
    const ct = allCompositeTasks.find((c) => c.id === draft.selectedId);
    return (
      <ReviewChipBody
        index={index}
        badge="COMPOSITE"
        title={ct?.title ?? '(unknown composite)'}
        meta={null}
        tone="library"
        onClick={onClick}
      />
    );
  }

  // inline
  const badge = draft.inlineType.toUpperCase();
  let title: string;
  let meta: string | null = null;
  if (draft.inlineType === 'counting') {
    title =
      draft.title.trim() ||
      `${draft.action.trim()} ${draft.maxCountStr.trim()} ${draft.unit.trim()}`.trim() ||
      '(untitled)';
    const count = parseInt(draft.maxCountStr, 10);
    if (!isNaN(count) && draft.action.trim() && draft.unit.trim()) {
      meta = `${count} ${draft.unit.trim()}`;
    }
  } else if (draft.inlineType === 'progress') {
    title = draft.title.trim() || '(untitled)';
    meta = `${draft.steps.length} step${draft.steps.length === 1 ? '' : 's'}`;
  } else {
    title = draft.title.trim() || '(untitled)';
  }
  return <ReviewChipBody index={index} badge={badge} title={title} meta={meta} tone="inline" />;
}

interface ReviewChipBodyProps {
  index: number;
  badge: string;
  title: string;
  meta: string | null;
  tone: 'library' | 'inline';
  onClick?: () => void;
}

function ReviewChipBody({
  index,
  badge,
  title,
  meta,
  tone,
  onClick,
}: ReviewChipBodyProps): React.ReactElement {
  const className = tone === 'inline' ? styles.chipInline : styles.chipLibrary;
  if (onClick) {
    return (
      <button
        type="button"
        className={className}
        onClick={onClick}
        aria-label={`Open ${title} in library`}
      >
        <span className={styles.chipIndex}>{index}</span>
        <span className={styles.chipBadge}>{badge}</span>
        <span className={styles.chipTitle}>{title}</span>
        {meta !== null && <span className={styles.chipMeta}>{meta}</span>}
      </button>
    );
  }
  return (
    <div className={className}>
      <span className={styles.chipIndex}>{index}</span>
      <span className={styles.chipBadge}>{badge}</span>
      <span className={styles.chipTitle}>{title}</span>
      {meta !== null && <span className={styles.chipMeta}>{meta}</span>}
    </div>
  );
}
