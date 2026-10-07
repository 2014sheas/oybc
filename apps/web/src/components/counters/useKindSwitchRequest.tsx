import { useState } from 'react';
import type { CountKind, Task } from '@oybc/shared';
import {
  planKindSwitchPreview,
  previewCounterKindSwitch,
  type KindSwitchPreview,
} from '../../db/operations/countKindSwitch';
import { KindSwitchConfirmDialog } from './KindSwitchConfirmDialog';
import { needsKindSwitchConfirm, switchedGoalText } from './kindSwitchModel';

/** What a preview needs — a stored task, or an editor draft for a pending one. */
export type KindSwitchSubject = Pick<
  Task,
  'id' | 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'
>;

/**
 * The one confirm seam for every editing sheet's kind picker (Ruling U7):
 * Continuous → Discrete opens the dialog (DB preview for a stored root, the
 * pure preview of `subject` for a pending task); confirming hands the new
 * kind and the rounded Goal text to `onSwitched` in one call. Every other
 * permitted change applies at once through `setKind`.
 *
 * @param args.subject - The task being edited (stored or pending).
 * @param args.kind - The kind the editor shows now.
 * @param args.goalText - The Goal field's current text.
 * @param args.onSwitched - Receives the confirmed kind + rounded goal text.
 * @param args.setKind - Applies a change that needs no confirm.
 * @returns `requestKind` for the picker's onChange, and the dialog to render (or null).
 */
export function useKindSwitchRequest(args: {
  subject: KindSwitchSubject;
  kind: CountKind;
  goalText: string;
  onSwitched: (kind: CountKind, goalText: string) => void;
  setKind: (k: CountKind) => void;
}): { requestKind: (next: CountKind) => void; dialog: React.ReactElement | null } {
  const [pending, setPending] = useState<KindSwitchPreview | null>(null);
  const requestKind = (next: CountKind): void => {
    if (!needsKindSwitchConfirm(args.kind, next)) {
      args.setKind(next);
      return;
    }
    // The editor's draft fields (goal text, title) may be ahead of the stored
    // row; the dialog previews the stored root's family when there is one,
    // else the draft itself.
    const fallback = (): KindSwitchPreview | null =>
      planKindSwitchPreview({ ...args.subject, countKind: args.kind }, next, 0);
    void previewCounterKindSwitch(args.subject.id, next)
      .catch(() => null)
      .then((p) => setPending(p ?? fallback()));
  };
  const dialog = pending ? (
    <KindSwitchConfirmDialog
      preview={pending}
      onCancel={() => setPending(null)}
      onConfirm={() => {
        args.onSwitched(pending.to, switchedGoalText(args.goalText, args.kind, pending.to));
        setPending(null);
      }}
    />
  ) : null;
  return { requestKind, dialog };
}
