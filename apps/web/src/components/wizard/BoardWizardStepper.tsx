import type { WizardStep } from '../../pages/createHub/useBoardWizard';
import styles from './BoardWizardStepper.module.css';

/** Board Creation Split (web PR C) — the middle step is "Tasks" for a
 *  one-off board (exact-count grid fill) and "Pool" for a recurring board
 *  (floor-fillable task pool, no grid). Setup/Preview labels are shared.
 *  Mirrors iOS `risoWizardSteps(isRecurring:)`. */
function stepsFor(isRecurring: boolean): { id: WizardStep; label: string }[] {
  return [
    { id: 1, label: 'Setup' },
    { id: 2, label: isRecurring ? 'Pool' : 'Tasks' },
    { id: 3, label: 'Preview' },
  ];
}

export interface BoardWizardStepperProps {
  currentStep: WizardStep;
  /** Board Creation Split (web PR C) — drives both the active-chip accent
   *  (red/blue) and the step-2 label (Tasks/Pool). Defaults to `false` so
   *  every existing one-off call site is unaffected. */
  isRecurring?: boolean;
  /** Called when the user taps a previous step's chip to jump back. Forward
   *  jumps are blocked (chip is rendered as disabled). */
  onStepClick?: (step: WizardStep) => void;
  /** When true, the stepper renders all chips but does not respond to taps. */
  readOnly?: boolean;
}

/**
 * BoardWizardStepper — Three-chip progress indicator for the wizard
 * shell. Highlights the current step and lets the user tap a previous
 * chip to jump back without losing state. Future steps are disabled.
 */
export function BoardWizardStepper({
  currentStep,
  isRecurring = false,
  onStepClick,
  readOnly = false,
}: BoardWizardStepperProps): React.ReactElement {
  const steps = stepsFor(isRecurring);
  return (
    <nav className={styles.stepper} aria-label="Wizard progress">
      {steps.map((step, index) => {
        const isActive = step.id === currentStep;
        const isComplete = step.id < currentStep;
        const isJumpable = !readOnly && step.id < currentStep && onStepClick !== undefined;
        return (
          <div key={step.id} className={styles.stepRow}>
            {index > 0 && <div className={styles.connector} aria-hidden="true" />}
            <button
              type="button"
              className={`${styles.chip} ${isActive ? styles.chipActive : ''} ${
                isComplete ? styles.chipComplete : ''
              } ${isActive && isRecurring ? styles.chipActiveBlue : ''}`}
              onClick={isJumpable ? () => onStepClick!(step.id) : undefined}
              disabled={!isJumpable && !isActive}
              aria-current={isActive ? 'step' : undefined}
            >
              <span className={styles.dot} aria-hidden="true">
                {isComplete ? '✓' : step.id}
              </span>
              <span className={styles.label}>{step.label}</span>
            </button>
          </div>
        );
      })}
    </nav>
  );
}
