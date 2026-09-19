import styles from './WizardEditModeNote.module.css';

interface WizardEditModeNoteProps {
  /** The repeating board being edited, or `null` for every other session. */
  editingTemplateId: string | null;
}

/**
 * WizardEditModeNote — the one muted line the wizard shows on EVERY step
 * while a person is editing an existing repeating board (Board Sources P4,
 * locked decision frame 5a): editing the board changes what the NEXT board
 * is built from, never the one already on the Boards tab.
 *
 * Renders nothing for a fresh session or a one-off board. Sits directly
 * under the stepper, mirroring iOS `BoardWizardView.swift`.
 *
 * Its own component (rather than an inline `<p>` in `BoardWizardPage`) so
 * the gate and the copy can be asserted without mounting the page, which
 * needs a router + an auth context.
 *
 * @param editingTemplateId - The repeating board under edit, or `null`.
 * @returns The note, or `null` when not editing.
 */
export function WizardEditModeNote({
  editingTemplateId,
}: WizardEditModeNoteProps): React.ReactElement | null {
  if (editingTemplateId === null) return null;
  return <p className={styles.editModeNote}>Changes apply from the next board.</p>;
}
