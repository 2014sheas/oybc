import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import { BoardSetupForm } from './BoardSetupForm';
import styles from './BoardWizardSetupStep.module.css';

export interface BoardWizardSetupStepProps {
  controller: BoardWizardController;
  onCancel: () => void;
  onNext: () => void;
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
 */
export function BoardWizardSetupStep({
  controller,
  onCancel,
  onNext,
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
            className={styles.nextButton}
            onClick={onNext}
            disabled={!isStep1Valid}
            title={!isStep1Valid ? (step1ValidationMessage ?? undefined) : undefined}
          >
            Next ›
          </button>
        </div>
      </div>
    </div>
  );
}
