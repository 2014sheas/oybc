import type { UserPreferences } from '@oybc/shared';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { useBoardWizard } from './createHub/useBoardWizard';
import { BoardWizardStepper } from '../components/wizard/BoardWizardStepper';
import { BoardWizardSetupStep } from '../components/wizard/BoardWizardSetupStep';
import { BoardWizardTasksStep } from '../components/wizard/BoardWizardTasksStep';
import { BoardWizardPreviewStepStub } from '../components/wizard/BoardWizardPreviewStepStub';
import styles from './BoardWizardPage.module.css';

export interface BoardWizardPageProps {
  /** Authenticated user id; threaded through to library reads + new-task writes. */
  userId: string;
  /** Synced preferences seed the wizard's defaults. */
  preferences: UserPreferences;
  /** Called when the user dismisses the wizard before activating. The
   *  smart cancel dialog (build-sequence step 4) wraps this. */
  onCancel: () => void;
  /** Called after a successful Activate or Save Draft (build-sequence
   *  step 3 wires the real DB writes; for now the stub fires this). */
  onComplete: (boardId: string, status: 'active' | 'draft') => void;
}

/**
 * BoardWizardPage — Orchestrator for the 3-step board-creation wizard.
 *
 * Owns the wizard controller (`useBoardWizard`) and the task library
 * (`useTaskLibrary`) and routes them into the active step component.
 * Step 3's full implementation (real DB writes, navigation to the
 * created board) is split out into `BoardWizardPreviewStepStub` for
 * the wizard-shell milestone; the full version replaces it in build
 * sequence step 3.
 */
export function BoardWizardPage({
  userId,
  preferences,
  onCancel,
  onComplete,
}: BoardWizardPageProps): React.ReactElement {
  const wizard = useBoardWizard({ preferences });
  const library = useTaskLibrary(userId);

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h2 className={styles.title}>New board</h2>
        <button
          type="button"
          className={styles.closeButton}
          onClick={onCancel}
          aria-label="Close wizard"
        >
          ✕
        </button>
      </header>

      <BoardWizardStepper currentStep={wizard.currentStep} onStepClick={wizard.goToStep} />

      <div className={styles.stepContainer}>
        {wizard.currentStep === 1 && (
          <BoardWizardSetupStep
            controller={wizard}
            onCancel={onCancel}
            onNext={wizard.goNext}
          />
        )}

        {wizard.currentStep === 2 && (
          <BoardWizardTasksStep
            library={library}
            selectedTaskIds={wizard.selectedTaskIds}
            onToggleSelection={wizard.toggleTaskSelection}
            tasksRequired={wizard.tasksRequired}
            centerTaskMode={wizard.centerMode}
            centerTaskId={wizard.centerTaskId}
            onCenterTaskChange={wizard.setCenterTaskId}
            userId={userId}
            onTaskCreated={(task) => wizard.toggleTaskSelection(task.id)}
            onCompositeCreated={() => {
              /* Composites are not boardable; the live library query
                 will surface the new composite automatically. */
            }}
            onBack={wizard.goBack}
            onNext={wizard.goNext}
          />
        )}

        {wizard.currentStep === 3 && (
          <BoardWizardPreviewStepStub
            controller={wizard}
            library={library}
            onBack={wizard.goBack}
            onActivate={() => onComplete('stub-board-id', 'active')}
            onSaveDraft={() => onComplete('stub-board-id', 'draft')}
          />
        )}
      </div>
    </div>
  );
}
