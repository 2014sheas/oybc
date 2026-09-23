import { useState } from 'react';
import type { BoardSource, BoardWindow, Task } from '@oybc/shared';
import type { SupplyInfoMap } from '../../pages/createHub/wizardSources';
import {
  seededTargetsForRemoval,
  sourceRemovalLossSentence,
  sourceRemovalNeedsConfirm,
} from '../../pages/createHub/wizardSourcesLogic';
import { RemoveSourceConfirmDialog } from './RemoveSourceConfirmDialog';

export interface UseRemoveSourceConfirmArgs {
  /** The wizard's pulled sources, in row order — the live read the pending
   *  confirm resolves against. */
  sources: BoardSource[];
  /** Per-source display/supply cache — the heading's name, and the window
   *  counts + source window the seed recomputation reads. */
  supplyInfoBySourceId: SupplyInfoMap;
  /**
   * LIBRARY-backed id → task (`library.taskMap`) — the same map the prefill
   * read, NOT the staged-edit overlay. An inline goal edit must not shift
   * the recomputed seed: the staged edit lives on the task and survives the
   * removal, so claiming "1 member rule" would be false.
   */
  taskById: Record<string, Task | undefined>;
  /** The window of the board being assembled (the prefill's target window). */
  wizardWindow: BoardWindow;
  /** True on a repeating-board session — the prefill never runs there, so
   *  every stored target is hand-set by definition. */
  isRecurring: boolean;
  /** The repeating board under edit, or `null` — appends the
   *  `WizardEditModeNote` line to the confirm. */
  editingTemplateId: string | null;
  /** The actual removal (`useBoardWizard.removeSource`). */
  onRemoveSource: (sourceId: string) => void;
}

export interface RemoveSourceConfirm {
  /**
   * The gate EVERY source-removal path calls (the row's ✕ and the source
   * sheet's un-toggle): a configured source opens the confirm, an untouched
   * one is removed on the spot.
   */
  requestRemoveSource: (source: BoardSource) => void;
  /** Render this somewhere in the step; `null` while no confirm is up. */
  removeSourceConfirm: React.ReactElement | null;
}

/**
 * useRemoveSourceConfirm — the wizard Tasks step's "are you sure?" before a
 * pulled source that carries configuration is dropped (owner ruling
 * 2026-09-19: a misclick on the row's ✕ was silently throwing away
 * exclusions, member rules, a narrowed range or a flipped squares filter;
 * an UNTOUCHED source still goes instantly).
 *
 * A hook rather than inline state because `BoardWizardTasksStep` is at its
 * god-file ceiling (`scripts/check-file-sizes.mjs`) — and because the gate
 * and the dialog are one indivisible piece of behaviour with two call sites,
 * so splitting them across the step would let one drift from the other. It
 * returns the dialog ELEMENT (not just the pending row) for the same reason:
 * there is exactly one correct way to render it.
 *
 * The pending source is held by ID and re-read from `sources` every render,
 * so a supply that resolves while the confirm is open can't leave it naming
 * a stale loss, and a source that disappears closes it.
 *
 * iOS twin: the `.confirmationDialog` + `pendingSourceRemoval` state in
 * `BoardWizardTasksStepView.swift`.
 *
 * @param args - See {@link UseRemoveSourceConfirmArgs}.
 * @returns The gate plus the dialog to render.
 */
export function useRemoveSourceConfirm({
  sources,
  supplyInfoBySourceId,
  taskById,
  wizardWindow,
  isRecurring,
  editingTemplateId,
  onRemoveSource,
}: UseRemoveSourceConfirmArgs): RemoveSourceConfirm {
  const [pendingId, setPendingId] = useState<string | null>(null);
  const pending = sources.find((s) => s.sourceId === pendingId) ?? null;

  /** What the one-off prefill would seed for this source RIGHT NOW —
   *  recomputed per call rather than remembered from the pull, so a
   *  timeframe change since then correctly reads as configuration. */
  const seeded = (source: BoardSource): Record<string, number> =>
    seededTargetsForRemoval(
      source,
      supplyInfoBySourceId[source.sourceId],
      taskById,
      wizardWindow,
      isRecurring,
    );

  const requestRemoveSource = (source: BoardSource): void => {
    if (sourceRemovalNeedsConfirm(source, seeded(source))) setPendingId(source.sourceId);
    else onRemoveSource(source.sourceId);
  };

  return {
    requestRemoveSource,
    removeSourceConfirm: pending && (
      <RemoveSourceConfirmDialog
        displayName={supplyInfoBySourceId[pending.sourceId]?.displayName ?? 'this source'}
        lossSentence={sourceRemovalLossSentence(pending, seeded(pending)) ?? ''}
        editingRepeatingBoard={editingTemplateId !== null}
        onCancel={() => setPendingId(null)}
        onConfirm={() => {
          onRemoveSource(pending.sourceId);
          setPendingId(null);
        }}
      />
    ),
  };
}
