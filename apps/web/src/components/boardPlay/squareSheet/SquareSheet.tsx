import { useEffect } from 'react';
import { createPortal } from 'react-dom';
import { useModalA11y } from '../../../hooks/useModalA11y';
import { RisoIcon, RisoTypeBadge } from '../../riso';
import type { SquareTaskType } from '../../interactiveTaskSquareUtils';
import styles from './SquareSheet.module.css';

export interface SquareSheetProps {
  type: SquareTaskType;
  title: string;
  /** The board's name when it is closed (sealed): a board line + CLOSED badge under the title. Absent = open. */
  closedBoardName?: string;
  onClose: () => void;
  onOpenInLibrary: () => void;
  children: React.ReactNode;
}

/**
 * SquareSheet — the one surface a tapped Counting / Compound / Achievement
 * square opens (docs/TASK_DETAIL_REDESIGN.md §C): a bottom sheet on phone, a
 * centred modal on desktop; type square · title · "Library ›" header over a
 * type-specific body. iOS twin: `SquareSheetView`.
 *
 * Portalled to <body> so it rises above the mobile bottom nav (the app
 * shell's <main> is its own stacking context).
 *
 * @returns The sheet.
 */
export function SquareSheet({ type, title, closedBoardName, onClose, onOpenInLibrary, children }: SquareSheetProps): React.ReactElement {
  const { ref, props: modalProps } = useModalA11y<HTMLDivElement>({ open: true, onCancel: onClose });
  // A chip disables while its write is in flight, which drops focus to <body>;
  // Escape must still dismiss the sheet from there.
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape' && e.target === document.body) onClose();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);
  return createPortal(
    <div className={styles.backdrop} onClick={onClose} role="presentation">
      <div ref={ref} className={styles.sheet} role="dialog" aria-label={title} {...modalProps} onClick={(e) => e.stopPropagation()}>
        <div className={styles.grabber} aria-hidden="true" />
        <div className={styles.header}>
          <RisoTypeBadge type={type} size="small" />
          <span className={styles.title}>{title}</span>
          <button type="button" className={styles.libraryPill} aria-label="Open in library" onClick={onOpenInLibrary}>
            Library
            <RisoIcon name="chevron" size={12} aria-hidden="true" />
          </button>
        </div>
        {closedBoardName !== undefined && (
          <div className={styles.closedHeader}>
            <span className={styles.closedBoard}>{closedBoardName}</span>
            <span className={styles.closedBadge}>
              <RisoIcon name="lock" size={9} />
              &nbsp;Closed
            </span>
          </div>
        )}
        <div className={styles.body}>{children}</div>
      </div>
    </div>,
    document.body,
  );
}
