import { useState } from 'react';
import type {
  RecurringBoardTemplate,
  Timeframe,
  UserPreferences,
} from '@oybc/shared';
import { useTaskLibrary } from './createPage/useTaskLibrary';
import { useBoardWizard, type BoardWizardDraft } from './createHub/useBoardWizard';
import { BoardWizardStepper } from '../components/wizard/BoardWizardStepper';
import { BoardWizardSetupStep } from '../components/wizard/BoardWizardSetupStep';
import { BoardWizardTasksStep } from '../components/wizard/BoardWizardTasksStep';
import { BoardWizardPreviewStep } from '../components/wizard/BoardWizardPreviewStep';
import { BoardWizardCancelDialog } from '../components/wizard/BoardWizardCancelDialog';
import {
  buildWizardPlacement,
  persistWizardBoard,
  resolveWizardDates,
} from '../components/wizard/wizardPersist';
import styles from './BoardWizardPage.module.css';

export interface BoardWizardPageProps {
  /** Authenticated user id; threaded through to library reads + new-task writes. */
  userId: string;
  /** Synced preferences seed the wizard's defaults. */
  preferences: UserPreferences;
  /** Optional draft payload. When provided, the wizard hydrates every
   *  field from the draft and Save / Activate actions update this
   *  record rather than create a new one. */
  draft?: BoardWizardDraft;
  /** When set, the wizard was opened from the Boards-tab Recurring
   *  Boards banner. The setup step locks the timeframe field so the
   *  user can't accidentally pick a different one (the seeded value
   *  comes from `useBoardWizard`'s `prefilledRecurringTimeframe`).
   *  Phase 6.1 of the Recurring Boards feature. */
  prefilledRecurringTimeframe?: Timeframe;
  /** When set, the wizard was opened from the core-board browser to
   *  spawn a non-current window. Passed straight through to the
   *  wizard controller; everything else (name seed, persist dates,
   *  recurring first-spawn window) keys off `controller.targetWindowDate`.
   *  Ignored when there's no `prefilledRecurringTimeframe`. */
  targetWindowDate?: Date;
  /** When set, the wizard was opened from Profile → Recurring
   *  templates → Edit. All fields hydrate from the template,
   *  `isRecurring` is forced ON, and Save updates the template
   *  instead of creating a new board. Phase 6.2 UX rework. */
  editingTemplate?: RecurringBoardTemplate;
  /** Issue #71 — when set, the wizard was opened from the Create hub's
   *  "Create a recurring board" CTA. Forces `isRecurring` ON at entry
   *  (no in-form toggle). The user picks the timeframe/size/center +
   *  pool, and Save creates a template + spawns the first board. */
  startRecurring?: boolean;
  /** Called when the user dismisses the wizard without persisting —
   *  either because they're in a pristine state (no edits) or they
   *  explicitly chose "Discard" in the smart-cancel dialog. */
  onCancel: () => void;
  /** Called after a successful Activate or Save Draft, including a
   *  Save-Draft triggered from the cancel dialog. `status` reflects
   *  the board's post-write status. In recurring mode this fires only
   *  when the spawn produced a board to land on. */
  onComplete: (boardId: string, status: 'active' | 'draft') => void;
  /** Phase 6.2: called when a recurring template was saved without a
   *  spawnable board (skip or edit). Parent should navigate to the
   *  Profile templates list. See `BoardWizardPreviewStep`'s prop docs
   *  for why this isn't folded into `onComplete`. */
  onTemplateComplete?: (templateId: string) => void;
}

/**
 * BoardWizardPage — Orchestrator for the 3-step board-creation wizard.
 *
 * Owns the wizard controller (`useBoardWizard`) and the task library
 * (`useTaskLibrary`) and routes them into the active step component.
 * Step 3 (`BoardWizardPreviewStep`) writes the new board to the local
 * DB on Activate / Save Draft. The cancel flow is routed through
 * `BoardWizardCancelDialog`: pristine states dismiss silently,
 * otherwise the user picks Save Draft / Discard / Keep Editing.
 */
export function BoardWizardPage({
  userId,
  preferences,
  draft,
  prefilledRecurringTimeframe,
  targetWindowDate,
  editingTemplate,
  startRecurring,
  onCancel,
  onComplete,
  onTemplateComplete,
}: BoardWizardPageProps): React.ReactElement {
  const wizard = useBoardWizard({
    preferences,
    userId,
    draft,
    prefilledRecurringTimeframe,
    targetWindowDate,
    editingTemplate,
    startRecurring,
  });
  const library = useTaskLibrary(userId);

  const [showCancelDialog, setShowCancelDialog] = useState(false);
  const [cancelDialogError, setCancelDialogError] = useState<string | null>(null);
  const [isSavingFromCancel, setIsSavingFromCancel] = useState(false);

  // Whether "Save Draft" in the cancel dialog can actually persist. We
  // require Step 1 to be minimally valid (name + resolvable dates) so
  // the Board record we write is well-formed. Partial task selection
  // is fine — drafts can have fewer BoardTasks than the geometry asks
  // for, and Activate will validate on the way out.
  const dates = resolveWizardDates(wizard, wizard.targetWindowDate ?? undefined);
  const hasResolvableDates = !('error' in dates);
  const hasName = wizard.name.trim().length > 0;
  const canSaveDraft = hasName && hasResolvableDates;
  const saveBlockedReason: string | undefined = !hasName
    ? 'Add a board name before saving as a draft.'
    : !hasResolvableDates && 'error' in dates
      ? String(dates.error)
      : undefined;

  /** Entry-point called by every "close wizard" affordance: the
   *  header ✕ and Step 1's Cancel footer button. */
  function handleCancelRequested(): void {
    if (wizard.isPristine) {
      onCancel();
      return;
    }
    setCancelDialogError(null);
    setShowCancelDialog(true);
  }

  async function handleDialogSaveDraft(): Promise<void> {
    setCancelDialogError(null);
    if (!canSaveDraft) return;
    if ('error' in dates) {
      setCancelDialogError(String(dates.error));
      return;
    }
    const resolvedDates = { startDate: dates.startDate, endDate: dates.endDate };
    setIsSavingFromCancel(true);
    try {
      const placement = buildWizardPlacement(wizard, library);
      const boardId = await persistWizardBoard({
        controller: wizard,
        library,
        userId,
        placement,
        dates: resolvedDates,
        status: 'draft',
      });
      setShowCancelDialog(false);
      onComplete(boardId, 'draft');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error.';
      setCancelDialogError(`Failed to save draft: ${msg}`);
    } finally {
      setIsSavingFromCancel(false);
    }
  }

  function handleDialogDiscard(): void {
    setShowCancelDialog(false);
    onCancel();
  }

  function handleDialogKeepEditing(): void {
    setShowCancelDialog(false);
    setCancelDialogError(null);
  }

  return (
    <div className={styles.shell}>
      <header className={styles.header}>
        <h2 className={styles.title}>
          {draft !== undefined
            ? 'Resume draft'
            : wizard.isRecurring
              ? editingTemplate !== undefined
                ? 'Edit recurring board'
                : 'New recurring board'
              : 'New board'}
        </h2>
        <button
          type="button"
          className={styles.closeButton}
          onClick={handleCancelRequested}
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
            onCancel={handleCancelRequested}
            onNext={wizard.goNext}
          />
        )}

        {wizard.currentStep === 2 && (
          <BoardWizardTasksStep
            library={library}
            selectedTaskIds={wizard.selectedTaskIds}
            onToggleSelection={wizard.toggleTaskSelection}
            tasksRequired={wizard.tasksRequired}
            isRecurring={wizard.isRecurring}
            centerTaskMode={wizard.centerMode}
            centerTaskId={wizard.centerTaskId}
            onCenterTaskChange={wizard.setCenterTaskId}
            userId={userId}
            currentTimeframe={wizard.timeframe}
            currentStartDate={'error' in dates ? undefined : dates.startDate}
            currentEndDate={'error' in dates ? undefined : dates.endDate}
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
          <BoardWizardPreviewStep
            controller={wizard}
            library={library}
            userId={userId}
            onBack={wizard.goBack}
            onComplete={onComplete}
            onTemplateComplete={onTemplateComplete}
          />
        )}
      </div>

      <BoardWizardCancelDialog
        isOpen={showCancelDialog}
        canSaveDraft={canSaveDraft && !isSavingFromCancel}
        saveDraftBlockedReason={saveBlockedReason}
        saveDraftLabel={
          isSavingFromCancel
            ? 'Saving…'
            : wizard.draftBoardId !== null
              ? 'Save Changes'
              : 'Save Draft'
        }
        onSaveDraft={() => void handleDialogSaveDraft()}
        onDiscard={handleDialogDiscard}
        onKeepEditing={handleDialogKeepEditing}
      />

      {cancelDialogError && (
        <div className={styles.globalError} role="alert">
          {cancelDialogError}
        </div>
      )}
    </div>
  );
}
