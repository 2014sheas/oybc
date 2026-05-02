import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import { BoardSetupForm } from './BoardSetupForm';
import styles from './BoardWizardSetupStep.module.css';

export interface BoardWizardSetupStepProps {
  controller: BoardWizardController;
  /** When true, render the Timeframe field as a read-only chip rather
   *  than the segmented selector. Used by the recurring-banner flow
   *  (Phase 6.1) so the user can't accidentally pick a different
   *  timeframe than the banner promised. */
  lockTimeframe?: boolean;
  onCancel: () => void;
  onNext: () => void;
}

/**
 * BoardWizardSetupStep — Step 1 of the wizard. Renders `BoardSetupForm`
 * wired to the wizard controller's state plus a footer with Cancel /
 * Next ›. The Next button reflects `controller.isStep1Valid`; an
 * inline tooltip surfaces the reason when disabled.
 */
export function BoardWizardSetupStep({
  controller,
  lockTimeframe = false,
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
    centerCustomName,
    setCenterCustomName,
    isRandomized,
    setIsRandomized,
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
        timeframeLocked={lockTimeframe}
        customStartDate={customStartDate}
        onCustomStartDateChange={setCustomStartDate}
        customEndDate={customEndDate}
        onCustomEndDateChange={setCustomEndDate}
        centerType={centerType}
        onCenterTypeChange={setCenterType}
        centerCustomName={centerCustomName}
        onCenterCustomNameChange={setCenterCustomName}
        isRandomized={isRandomized}
        onIsRandomizedChange={setIsRandomized}
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
