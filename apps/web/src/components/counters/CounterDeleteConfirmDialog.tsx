import styles from './CounterDeleteConfirmDialog.module.css';

/** One linked member row shown in the confirm dialog's unlink list. */
export interface CounterDeleteConfirmMember {
  /** The member task's id (React key). */
  id: string;
  /** The member task's display title. */
  title: string;
  /** The board it's placed on, or null when unplaced. */
  boardName: string | null;
}

export interface CounterDeleteConfirmDialogProps {
  /** The counter's display name (hero-card name / group.name). */
  counterName: string;
  /** `impact.counterMemberCount` — number of live tasks linked to this counter. */
  memberCount: number;
  /** Member rows to list (title + board name where placed). */
  members: CounterDeleteConfirmMember[];
  /** True while `deleteCounterWithUnlink` is in flight — disables both actions
   *  so a second click can't fire a duplicate delete (mirrors CreateCounterSheet's
   *  busy guard). */
  busy: boolean;
  /** Confirm — caller awaits `deleteCounterWithUnlink` then navigates away. */
  onConfirm: () => void;
  /** Cancel / dismiss. */
  onCancel: () => void;
}

/**
 * CounterDeleteConfirmDialog — destructive confirmation sheet for deleting a
 * shared-counter source (P5 decision 8: `deleteCounterWithUnlink`).
 *
 * Modeled on `pages/tasks/TaskConfirmDeleteDialog.tsx` (backdrop + `sheet` +
 * `role="alertdialog"` + red destructive confirm button), adapted for the
 * counter-specific copy: the lifetime total is being deleted (not just a
 * library row), and linked members are UNLINKED (keep their current counts
 * as independent standalone counters) rather than cascade-deleted.
 */
export function CounterDeleteConfirmDialog({
  counterName,
  memberCount,
  members,
  busy,
  onConfirm,
  onCancel,
}: CounterDeleteConfirmDialogProps): React.ReactElement {
  const hasMembers = memberCount > 0;

  return (
    <div className={styles.backdrop} onClick={() => !busy && onCancel()}>
      <div
        className={styles.sheet}
        role="alertdialog"
        aria-label="Confirm delete counter"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Delete counter?</h2>
        <p className={styles.confirmBody}>
          &apos;{counterName}&apos; and its lifetime total will be deleted.
        </p>

        {hasMembers && (
          <div className={styles.membersSection}>
            <p className={styles.membersHeading}>
              {memberCount} linked task{memberCount === 1 ? '' : 's'} will be
              unlinked and keep their current counts:
            </p>
            <ul className={styles.membersList}>
              {members.map((m) => (
                <li key={m.id} className={styles.membersItem}>
                  <span className={styles.membersTitle}>{m.title}</span>
                  {m.boardName && (
                    <span className={styles.membersBoard}>{m.boardName}</span>
                  )}
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            className={styles.cancelButton}
            disabled={busy}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.deleteButton}
            disabled={busy}
            onClick={onConfirm}
          >
            Delete counter{hasMembers ? ` & unlink ${memberCount} tasks` : ''}
          </button>
        </div>
      </div>
    </div>
  );
}
