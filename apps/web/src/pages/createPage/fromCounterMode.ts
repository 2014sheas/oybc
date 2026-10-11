import { TaskType } from '@oybc/shared';

/**
 * The "+ New" from-counter mode (Counter Detail's unit-task creator;
 * docs/SHARED_COUNTER_SETTINGS.md §3, unit-tasks handoff §B): the new task is
 * a unit task of the counter, so the type control drops Achievement (absent,
 * not disabled) and a counting create never auto-links — a unit task may not
 * be a linked copy. iOS twin: `allowAchievement: false` + the suppressed
 * `RisoCounterLinkHintView` in `RisoSpecialTaskPanel`.
 */

/**
 * @param types - The type options the host offers.
 * @param preset - The counter the sheet was opened from, or null.
 * @returns `types` without Achievement when a preset is active, else unchanged.
 */
export function typesForPreset<T extends { value: TaskType }>(types: T[], preset: string | null): T[] {
  return preset == null ? types : types.filter((t) => t.value !== TaskType.ACHIEVEMENT);
}

/**
 * @param onCreateLinked - The host's auto-link create, when wired.
 * @param preset - The counter the sheet was opened from, or null.
 * @returns The auto-link create to honour — `undefined` (no hint, no link) under a preset.
 */
export function autoLinkCreateForPreset<T>(onCreateLinked: T | undefined, preset: string | null): T | undefined {
  return preset == null ? onCreateLinked : undefined;
}
