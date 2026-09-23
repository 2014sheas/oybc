import type {
  BoardSource,
  BoardWindow,
  CompoundChild,
  PlanMode,
  Task,
  VaryLevel,
} from '@oybc/shared';
import type { SupplyInfoMap } from '../../pages/createHub/wizardSources';
import { SourceRow } from './SourceRow';

/** An unresolved source renders as an empty row rather than vanishing. */
const EMPTY_SUPPLY = {
  displayName: '',
  rawSupplyTaskIds: [] as string[],
  doneTaskIds: new Set<string>(),
};

export interface WizardSourceRowsProps {
  /** Pulled sources in row order (`useBoardWizard.sources`). */
  sources: BoardSource[];
  supplyInfoBySourceId: SupplyInfoMap;
  /** Post-exclude/post-filter available count (the range slider's N). */
  availableCountForSource: (sourceId: string) => number;
  expandedSourceIds: Set<string>;
  /** Staged-edit-overlaid task map, so inline renames show through. */
  taskById: Record<string, Task>;
  counterClashByTaskId?: Map<string, string>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  /** One-off or repeating — drives the member rows' target wording. */
  mode: PlanMode;
  /** The window of the board being assembled (pro-rating target window). */
  wizardWindow: BoardWindow;
  onToggleExpanded: (sourceId: string) => void;
  /** The remove GATE, not the removal — see `useRemoveSourceConfirm`. */
  onRemove: (source: BoardSource) => void;
  onSetFilter: (sourceId: string, filter: 'all' | 'todo') => void;
  onSetRange: (sourceId: string, min: number, max: number | null) => void;
  onToggleExclude: (sourceId: string, taskId: string) => void;
  onSetMemberTarget: (sourceId: string, taskId: string, target: number | undefined) => void;
  onSetMemberVary: (sourceId: string, taskId: string, level: VaryLevel) => void;
  onSetMemberSplit: (sourceId: string, taskId: string, split: boolean) => void;
  onSetPartExcluded: (
    sourceId: string,
    taskId: string,
    childId: string,
    excluded: boolean,
  ) => void;
  onSetPartTarget: (
    sourceId: string,
    taskId: string,
    childId: string,
    target: number | undefined,
  ) => void;
  onSetPartVary: (sourceId: string, taskId: string, childId: string, level: VaryLevel) => void;
}

/**
 * WizardSourceRows — the pulled-source rows that lead the Tasks step's "On
 * your board" list, ahead of the hand-added task rows.
 *
 * Pure prop-forwarding: it exists so the per-source `sourceId` currying
 * (twenty closures per row) lives somewhere other than
 * `BoardWizardTasksStep`, which sits at its god-file ceiling
 * (`scripts/check-file-sizes.mjs`). Mirrors iOS's `sourceRowsList` in
 * `BoardWizardTasksStepView.swift`, which is a separate computed view for
 * the same reason.
 *
 * @param props - See {@link WizardSourceRowsProps}.
 * @returns One {@link SourceRow} per pulled source.
 */
export function WizardSourceRows({
  sources,
  supplyInfoBySourceId,
  availableCountForSource,
  expandedSourceIds,
  taskById,
  counterClashByTaskId,
  compoundChildrenByCompound,
  mode,
  wizardWindow,
  onToggleExpanded,
  onRemove,
  onSetFilter,
  onSetRange,
  onToggleExclude,
  onSetMemberTarget,
  onSetMemberVary,
  onSetMemberSplit,
  onSetPartExcluded,
  onSetPartTarget,
  onSetPartVary,
}: WizardSourceRowsProps): React.ReactElement {
  return (
    <>
      {sources.map((source) => {
        const id = source.sourceId;
        return (
          <SourceRow
            key={id}
            source={source}
            supply={supplyInfoBySourceId[id] ?? EMPTY_SUPPLY}
            availableCount={availableCountForSource(id)}
            isExpanded={expandedSourceIds.has(id)}
            taskById={taskById}
            onToggleExpanded={() => onToggleExpanded(id)}
            onRemove={() => onRemove(source)}
            onSetFilter={(filter) => onSetFilter(id, filter)}
            onSetRange={(min, max) => onSetRange(id, min, max)}
            onToggleExclude={(taskId) => onToggleExclude(id, taskId)}
            counterClashByTaskId={counterClashByTaskId}
            compoundChildrenByCompound={compoundChildrenByCompound}
            mode={mode}
            wizardWindow={wizardWindow}
            onSetMemberTarget={(taskId, target) => onSetMemberTarget(id, taskId, target)}
            onSetMemberVary={(taskId, level) => onSetMemberVary(id, taskId, level)}
            onSetMemberSplit={(taskId, split) => onSetMemberSplit(id, taskId, split)}
            onSetPartExcluded={(taskId, childId, excluded) =>
              onSetPartExcluded(id, taskId, childId, excluded)
            }
            onSetPartTarget={(taskId, childId, target) =>
              onSetPartTarget(id, taskId, childId, target)
            }
            onSetPartVary={(taskId, childId, level) => onSetPartVary(id, taskId, childId, level)}
          />
        );
      })}
    </>
  );
}
