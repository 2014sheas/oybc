import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import { BoardSetupForm } from './BoardSetupForm';
import styles from './BoardWizardSetupStep.module.css';

export interface BoardWizardSetupStepProps {
  controller: BoardWizardController;
  onCancel: () => void;
  onNext: () => void;
  /** Profile reorg PR3 — "Delete repeating board". Rendered as a quiet red
   *  danger row at the bottom of the card ONLY while the wizard is editing
   *  an existing repeating board (`controller.editingTemplateId !== null`)
   *  AND the parent wires it. The parent (`BoardWizardPage`) owns the
   *  confirm dialog + the soft-delete; this step only asks. */
  onDeleteRepeatingBoard?: () => void;
}

/**
 * BoardWizardSetupStep — Step 1 of the wizard. Renders `BoardSetupForm`
 * wired to the wizard controller's state plus a footer with Cancel /
 * Next ›. The Next button reflects `controller.isStep1Valid`; an
 * inline tooltip surfaces the reason when disabled.
 *
 * The form's layout (one-off / recurring / core) is driven by the
 * controller's read-only `isRecurring` / `isCore` flags, both set at
 * wizard entry — there's no in-step timeframe lock or recurring toggle.
 *
 * Edit mode (Profile reorg PR3): a "Delete repeating board" danger row sits
 * at the bottom of the card. It lives on THIS step — the one the editor
 * lands on — rather than the last step because the stepper only jumps
 * backwards and the Pool step's Next is capacity-gated, so an under-filled
 * repeating board could never reach a Preview-step Delete. iOS twin:
 * `BoardWizardSetupStepView.onDeleteRepeatingBoard`.
 */
export function BoardWizardSetupStep({
  controller,
  onCancel,
  onNext,
  onDeleteRepeatingBoard,
}: BoardWizardSetupStepProps): React.ReactElement {
  const {
    name,
    setName,
    size,
    setSize,
    timeframe,
    setTimeframe,
    customStartDate,
    setCustomStartDate,
    customEndDate,
    setCustomEndDate,
    centerType,
    setCenterType,
    isRecurring,
    isCore,
    weekStartDay,
    isStep1Valid,
    step1ValidationMessage,
  } = controller;

  return (
    <div className={styles.container}>
      <BoardSetupForm
        name={name}
        onNameChange={setName}
        size={size}
        onSizeChange={setSize}
        timeframe={timeframe}
        onTimeframeChange={setTimeframe}
        customStartDate={customStartDate}
        onCustomStartDateChange={setCustomStartDate}
        customEndDate={customEndDate}
        onCustomEndDateChange={setCustomEndDate}
        centerType={centerType}
        onCenterTypeChange={setCenterType}
        isRecurring={isRecurring}
        isCore={isCore}
        weekStartDay={weekStartDay}
      />

      <div className={styles.footer}>
        {step1ValidationMessage && !isStep1Valid && (
          <span className={styles.footerMessage}>{step1ValidationMessage}</span>
        )}
        <div className={styles.footerButtons}>
          <button type="button" className={styles.cancelButton} onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            // Board Creation Split (web PR C) — Next's accent tracks the
            // wizard's fixed mode: red one-off / blue recurring.
            className={`${styles.nextButton} ${isRecurring ? styles.nextButtonBlue : ''}`}
            onClick={onNext}
            disabled={!isStep1Valid}
            title={!isStep1Valid ? (step1ValidationMessage ?? undefined) : undefined}
          >
            Next ›
          </button>
        </div>
      </div>

      {controller.editingTemplateId !== null && onDeleteRepeatingBoard && (
        <div className={styles.dangerRow}>
          <button type="button" className={styles.deleteLink} onClick={onDeleteRepeatingBoard}>
            Delete repeating board
          </button>
        </div>
      )}
    </div>
  );
}
