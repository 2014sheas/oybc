import {
  COUNT_KINDS,
  COUNT_KIND_LABELS,
  isKindSegmentLocked,
  kindSegmentShowsLock,
  type CountKind,
  type KindPickerLock,
} from '@oybc/shared';
import { RisoSegmented } from '../riso';

export interface KindPickerProps {
  /** The selected kind. */
  value: CountKind;
  /** Lock state — `kindPickerLock(mode, kind)`. */
  lock: KindPickerLock;
  /** Called with a live (unlocked) segment's kind. The caller confirms Continuous → Discrete (Task 8). */
  onChange: (kind: CountKind) => void;
  /** `compact` for dense rows (compound sub-task, pool row). */
  size?: 'default' | 'compact';
}

/**
 * The one counter-kind picker (docs/COUNTER_KINDS.md §5) — a full-width
 * three-segment card `RisoSegmented` with the D4 lock states. iOS twin:
 * `KindPickerView`.
 *
 * @returns The picker.
 */
export function KindPicker({ value, lock, onChange, size = 'default' }: KindPickerProps): React.ReactElement {
  return (
    <RisoSegmented<CountKind>
      aria-label="Kind"
      variant="card"
      fullWidth
      size={size}
      options={COUNT_KINDS.map((k) => ({ value: k, label: COUNT_KIND_LABELS[k] }))}
      value={value}
      onChange={onChange}
      lockedValues={COUNT_KINDS.filter((k) => isKindSegmentLocked(lock, k))}
      lockGlyphValues={COUNT_KINDS.filter((k) => kindSegmentShowsLock(lock, k, value))}
    />
  );
}
