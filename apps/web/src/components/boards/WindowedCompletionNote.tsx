import { useState } from 'react';
import { RisoIcon } from '../riso';
import styles from './Boards.module.css';

/**
 * localStorage key persisting one-time dismissal of the Windowed Completion
 * upgrade note. Presence of the key = the user has seen + dismissed it.
 */
const WC_NOTE_DISMISSED_KEY = 'oybc.windowedCompletionNoteDismissed.v1';

function readDismissed(): boolean {
  try {
    return localStorage.getItem(WC_NOTE_DISMISSED_KEY) === '1';
  } catch {
    // Private-mode / storage-disabled: fail toward showing once (harmless).
    return false;
  }
}

/**
 * WindowedCompletionNote — the one-time in-app upgrade note required by the
 * Windowed Completion rollout (docs/WINDOWED_COMPLETION.md §What changes
 * visibly at upgrade). After the migration, live boards re-evaluate under
 * windowed semantics: a task completed *before* a board started no longer
 * carries its green onto that board. That is user-visible and would look like
 * data loss without a word of explanation.
 *
 * Deliberately minimal (#151): a single dismissible Boards-tab banner, shown
 * once and remembered via localStorage. Copy stays strictly functional. It is
 * NOT gated on whether the current device actually had bleed-greens — every
 * upgraded device shows it once, matching the "ship a one-time note with the
 * upgrade" instruction, then never again.
 */
export function WindowedCompletionNote(): React.ReactElement | null {
  const [dismissed, setDismissed] = useState<boolean>(() => readDismissed());
  if (dismissed) return null;

  function dismiss(): void {
    try {
      localStorage.setItem(WC_NOTE_DISMISSED_KEY, '1');
    } catch {
      // Ignore — worst case the note reappears next load.
    }
    setDismissed(true);
  }

  return (
    <div className={styles.wcNote} role="region" aria-label="What's new">
      <div className={styles.wcNoteBody}>
        <div className={styles.wcNoteHead}>
          <RisoIcon name="repeat" size={13} aria-hidden />
          What&apos;s new
        </div>
        <div className={styles.wcNoteText}>
          Boards now track each window&apos;s work — squares completed before a
          board started no longer carry over.
        </div>
      </div>
      <button
        type="button"
        className={styles.wcNoteDismiss}
        onClick={dismiss}
        aria-label="Dismiss what's-new note"
      >
        Got it
      </button>
    </div>
  );
}
