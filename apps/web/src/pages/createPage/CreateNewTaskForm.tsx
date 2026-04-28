import { TaskType, type Task } from '@oybc/shared';
import { TaskTypeSelector } from '../../components/TaskTypeSelector';
import { ProgressStepRow } from '../../components/ProgressStepRow';
import { CompositeTaskWizard } from '../../components/compositeWizard/CompositeTaskWizard';
import { CountingTemplatePicker } from '../../components/wizard/CountingTemplatePicker';
import { getCharCountClass } from '../../components/playground/playgroundUtils';
import { COMPOSITE_TYPE, PROGRESS_TYPE, type TaskTypeOrComposite } from './useCreateFormState';
import {
  type UseCreateFormState,
  TITLE_MAX_LENGTH,
  DESCRIPTION_MAX_LENGTH,
  ACTION_MAX_LENGTH,
  UNIT_MAX_LENGTH,
  STEP_TITLE_MAX_LENGTH,
} from './useCreateFormState';
import styles from './CreateNewTaskForm.module.css';

const TASK_TYPES: { value: TaskTypeOrComposite; label: string }[] = [
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: PROGRESS_TYPE, label: 'Progress' },
  { value: COMPOSITE_TYPE, label: 'Composite' },
];

/**
 * Renders the "Create New" tab: the type selector, per-type form
 * fields, progress steps, and the submit button. Composite selection
 * swaps to `CompositeTaskWizard` (owns its own state). All other state
 * comes from `useCreateFormState` via the `form` prop.
 *
 * Kept as a pure presentation component — no data-layer calls, no
 * DB imports. The `onCompositeCreated` callback lets the parent decide
 * what to do when a composite is built (typically: flash a success
 * toast directing the user to the Existing Tasks tab).
 */
export interface CreateNewTaskFormProps {
  form: UseCreateFormState;
  userId: string | undefined;
  /** Called with the newly-created compound Task when the user finishes the wizard. */
  onCompositeCreated: (task: Task) => void;
  /** Label for the submit button. Defaults to the legacy pool-flow wording. */
  submitLabel?: string;
}

export function CreateNewTaskForm({
  form,
  userId,
  onCompositeCreated,
  submitLabel = 'Create & Add to Pool',
}: CreateNewTaskFormProps): React.ReactElement {
  return (
    <div className={styles.modeSection}>
      <div className={styles.fieldGroup}>
        <label className={styles.label}>
          Type<span className={styles.required}>*</span>
        </label>
        <TaskTypeSelector
          types={TASK_TYPES}
          selectedType={form.taskType}
          onTypeChange={(value) => form.handleTypeChange(value as TaskTypeOrComposite)}
        />
      </div>

      {form.taskType === COMPOSITE_TYPE ? (
        <CompositeTaskWizard userId={userId} onCreated={onCompositeCreated} />
      ) : (
        <form className={styles.form} onSubmit={form.handleSubmit}>
          {/* Title */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="create-task-title">
              Title
              {form.taskType !== TaskType.COUNTING && <span className={styles.required}>*</span>}
            </label>
            <input
              id="create-task-title"
              type="text"
              className={`${styles.input} ${form.errors.title ? styles.inputError : ''}`}
              value={form.title}
              onChange={(e) => form.setTitle(e.target.value)}
              placeholder={
                form.taskType === TaskType.COUNTING
                  ? 'Auto-generated if blank (e.g., "Run 26 miles")'
                  : 'Enter task title'
              }
              maxLength={TITLE_MAX_LENGTH + 1}
            />
            <span className={getCharCountClass(form.title.length, TITLE_MAX_LENGTH, styles)}>
              {form.title.length}/{TITLE_MAX_LENGTH}
            </span>
            {form.errors.title && <span className={styles.fieldError}>{form.errors.title}</span>}
          </div>

          {/* Description */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="create-task-description">
              Description
            </label>
            <textarea
              id="create-task-description"
              className={`${styles.input} ${styles.textarea} ${form.errors.description ? styles.inputError : ''}`}
              value={form.description}
              onChange={(e) => form.setDescription(e.target.value)}
              placeholder="Enter task description (optional)"
              maxLength={DESCRIPTION_MAX_LENGTH + 1}
            />
            <span className={getCharCountClass(form.description.length, DESCRIPTION_MAX_LENGTH, styles)}>
              {form.description.length}/{DESCRIPTION_MAX_LENGTH}
            </span>
            {form.errors.description && <span className={styles.fieldError}>{form.errors.description}</span>}
          </div>

          {/* Counting fields */}
          {form.taskType === TaskType.COUNTING && (
            <div className={styles.countingFields}>
              {/* "Derive from existing" affordance — only when userId is
                 resolved. Rendering with `userId === undefined` shows a stale
                 "No counting tasks yet" empty-state during auth load. */}
              {userId != null && (
                <CountingTemplatePicker
                  userId={userId}
                  selectedTemplate={form.deriveFromTask}
                  onSelect={form.applyTemplate}
                  onClear={form.clearTemplate}
                />
              )}

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-action">
                  Action<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-action"
                  type="text"
                  className={`${styles.input} ${form.errors.action ? styles.inputError : ''}`}
                  value={form.action}
                  onChange={(e) => form.setAction(e.target.value)}
                  placeholder='e.g., "Run"'
                  maxLength={ACTION_MAX_LENGTH}
                />
                {form.errors.action && <span className={styles.fieldError}>{form.errors.action}</span>}
              </div>

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-maxcount">
                  Max Count<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-maxcount"
                  type="number"
                  className={`${styles.input} ${form.errors.maxCount ? styles.inputError : ''}`}
                  value={form.maxCountStr}
                  onChange={(e) => form.setMaxCountStr(e.target.value)}
                  placeholder="e.g., 26"
                  min="1"
                />
                {form.errors.maxCount && <span className={styles.fieldError}>{form.errors.maxCount}</span>}
              </div>

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-unit">
                  Unit<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-unit"
                  type="text"
                  className={`${styles.input} ${form.errors.unit ? styles.inputError : ''}`}
                  value={form.unit}
                  onChange={(e) => form.setUnit(e.target.value)}
                  placeholder='e.g., "miles"'
                  maxLength={UNIT_MAX_LENGTH}
                />
                {form.errors.unit && <span className={styles.fieldError}>{form.errors.unit}</span>}
              </div>
            </div>
          )}

          {/* Progress steps */}
          {form.taskType === PROGRESS_TYPE && (
            <div className={styles.stepsSection}>
              <span className={styles.stepsHeader}>Steps</span>
              <div className={styles.stepsList}>
                {form.steps.map((step, index) => (
                  <ProgressStepRow
                    key={step.id}
                    index={index}
                    idPrefix={`create-step-${step.id}`}
                    step={step}
                    errors={form.errors.steps?.[step.id]}
                    canRemove={form.steps.length > 1}
                    stepTitleMaxLength={STEP_TITLE_MAX_LENGTH}
                    onFieldChange={(field, value) => form.updateStep(step.id, field, value)}
                    onRemove={() => form.removeStep(step.id)}
                  />
                ))}
              </div>
              <button type="button" className={styles.addStepButton} onClick={form.addStep}>
                + Add Step
              </button>
            </div>
          )}

          {form.errors.general && <div className={styles.errorMessage}>{form.errors.general}</div>}

          <button type="submit" className={styles.submitButton} disabled={form.isSubmitting}>
            {form.isSubmitting ? 'Creating...' : submitLabel}
          </button>
        </form>
      )}
    </div>
  );
}
