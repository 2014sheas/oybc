/**
 * Non-component helpers + types for the compound-task creation subtask
 * forms. Consumed by the compound-task wizard (CompoundTaskWizard,
 * compoundSubtaskDraft) and useCreateFormState. (The original
 * `ProgressStepRow` component was removed as dead code; these shared
 * helpers live on.)
 */

/**
 * Form state for a single inline subtask in a compound-task creation form.
 * Exported so parent components (ProgressTaskCreationPlayground,
 * UnifiedTaskCreatorPlayground) share a single type definition.
 */
export interface SubtaskFormState {
  id: string;
  title: string;
  type: 'normal' | 'counting';
  action: string;
  unit: string;
  maxCount: string;
}

/**
 * Validation error state for a single inline subtask.
 * Exported so parent FormErrors types can reference it.
 */
export interface SubtaskFormErrors {
  title?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
}

/**
 * Generates a unique client-side ID for form subtask tracking.
 *
 * @returns A unique string ID
 */
export function generateFormId(): string {
  return crypto.randomUUID();
}

/**
 * Creates a new empty subtask form state.
 *
 * @returns A fresh SubtaskFormState with default values
 */
export function createEmptySubtask(): SubtaskFormState {
  return {
    id: generateFormId(),
    title: '',
    type: 'normal',
    action: '',
    unit: '',
    maxCount: '',
  };
}
