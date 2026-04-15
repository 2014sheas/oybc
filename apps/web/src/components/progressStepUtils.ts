/**
 * Non-component helpers + types shared by `ProgressStepRow` and its
 * parent forms. Split out from `ProgressStepRow.tsx` so that file
 * exports components only — required for Fast Refresh / HMR.
 */

/**
 * Form state for a single step in a progress task creation form.
 * Exported so parent components (ProgressTaskCreationPlayground,
 * UnifiedTaskCreatorPlayground) share a single type definition.
 */
export interface StepFormState {
  id: string;
  title: string;
  type: 'normal' | 'counting';
  action: string;
  unit: string;
  maxCount: string;
}

/**
 * Validation error state for a single progress step.
 * Exported so parent FormErrors types can reference it.
 */
export interface StepFormErrors {
  title?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
}

/**
 * Generates a unique client-side ID for form step tracking.
 *
 * @returns A unique string ID
 */
export function generateFormId(): string {
  return crypto.randomUUID();
}

/**
 * Creates a new empty step form state.
 *
 * @returns A fresh StepFormState with default values
 */
export function createEmptyStep(): StepFormState {
  return {
    id: generateFormId(),
    title: '',
    type: 'normal',
    action: '',
    unit: '',
    maxCount: '',
  };
}
