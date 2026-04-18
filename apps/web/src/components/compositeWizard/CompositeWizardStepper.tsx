import styles from './CompositeWizardStepper.module.css';

export type CompositeWizardStep = 1 | 2 | 3;

const STEPS: { id: CompositeWizardStep; label: string }[] = [
  { id: 1, label: 'Setup' },
  { id: 2, label: 'Build' },
  { id: 3, label: 'Review' },
];

export interface CompositeWizardStepperProps {
  currentStep: CompositeWizardStep;
  /** Tapping a completed chip jumps back to that step. Future steps
   *  (> currentStep) are disabled so users can't skip validation. */
  onStepClick?: (step: CompositeWizardStep) => void;
}

/**
 * 3-chip header for the composite-task mini-wizard. Visual style
 * matches the board-creation stepper so users see a consistent
 * multi-step pattern across the app.
 */
export function CompositeWizardStepper({
  currentStep,
  onStepClick,
}: CompositeWizardStepperProps): React.ReactElement {
  return (
    <nav className={styles.stepper} aria-label="Composite wizard progress">
      {STEPS.map((step, idx) => {
        const isActive = step.id === currentStep;
        const isComplete = step.id < currentStep;
        const isJumpable = isComplete && onStepClick !== undefined;

        const chipClass = [
          styles.chip,
          isActive ? styles.chipActive : '',
          isComplete ? styles.chipComplete : '',
        ].filter(Boolean).join(' ');

        return (
          <div key={step.id} className={styles.stepRow}>
            {idx > 0 && <div className={styles.connector} />}
            <button
              type="button"
              className={chipClass}
              onClick={() => isJumpable && onStepClick?.(step.id)}
              disabled={!isJumpable && !isActive}
              aria-label={`${step.label} step${isActive ? ', current' : isComplete ? ', complete' : ''}`}
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
