import type { RecurringBoardTemplate, UserPreferences } from '@oybc/shared';
import { BoardWizardPage } from '../../pages/BoardWizardPage';
import styles from './RepeatingBoardWizardOverlay.module.css';

export interface RepeatingBoardWizardOverlayProps {
  /** Authenticated user id; threaded through to the wizard unchanged. */
  userId: string;
  /** Synced preferences; threaded through to the wizard unchanged. */
  preferences: UserPreferences;
  /** The repeating board (spawn record) being edited. */
  template: RecurringBoardTemplate;
  /** Cancel / Save Changes / spawn-skipped-on-edit (unreachable — edits
   *  never spawn) all close back to Board settings, which reloads via its
   *  own reactive queries. */
  onClose: () => void;
}

/**
 * RepeatingBoardWizardOverlay — Board Creation Split (web PR D). Board
 * settings' "Edit tasks" affordance now opens the FULL recurring wizard in
 * EDIT mode (kicker "EDIT RECURRING BOARD", schedule note "Changes apply
 * from the next board · current board keeps playing", footer Cancel /
 * "Save Changes") instead of the retired local `RosterEditSheet`.
 *
 * Mirrors iOS `BoardSettingsView`'s
 * `.fullScreenCover(item: $rosterEditTarget) { BoardWizardView(editingTemplate:) }`
 * — web has no native full-screen-cover primitive, so this is a fixed,
 * full-viewport overlay (same z-index tier as the app's other full-screen
 * sheets, e.g. the retired `RosterEditSheet.module.css`'s `.backdrop`)
 * wrapping `BoardWizardPage` completely unchanged; the wizard itself
 * already knows how to render in `editingTemplate` mode.
 *
 * Pause/Resume stays a direct roster-row toggle
 * (`RepeatingBoardRow.toggleActive`) — no wizard hop.
 */
export function RepeatingBoardWizardOverlay({
  userId,
  preferences,
  template,
  onClose,
}: RepeatingBoardWizardOverlayProps): React.ReactElement {
  return (
    <div className={styles.overlay} role="dialog" aria-modal="true" aria-label="Edit recurring board">
      <div className={styles.canvas}>
        <BoardWizardPage
          userId={userId}
          preferences={preferences}
          editingTemplate={template}
          onCancel={onClose}
          onComplete={onClose}
          onTemplateComplete={onClose}
        />
      </div>
    </div>
  );
}
