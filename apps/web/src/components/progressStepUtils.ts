/**
 * Non-component helpers + types for progress/counting step forms.
 * Consumed by the composite-task wizard (CompositeTaskWizard,
 * compositeSubtaskDraft) and useCreateFormState. (The original
 * `ProgressStepRow` component was removed as dead code; these shared
 * helpers live on.)
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
