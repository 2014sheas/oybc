import { useCallback, useEffect, useRef, useState } from 'react';
import { toBlob } from 'html-to-image';
import type { PosterCell } from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { SharePoster } from './SharePoster';
import { shareFilename, shareSheetTitle, shareText, shareTitle, type ShareKind } from './sharePosterModel';
import { RisoButton, RisoIcon } from '../riso';
import styles from './ShareBoardSheet.module.css';

export interface ShareBoardSheetProps {
  /** Which moment's poster: a bingo (blue) or a greenlog (green). */
  kind: ShareKind;
  boardName: string;
  boardSize: number;
  /** The moment's end-state cells (`momentPosterCells`), row-major. */
  cells: PosterCell[];
  completedTasks: number;
  totalTasks: number;
  linesCompleted: number;
  /**
   * Compact streak label ("2w") for the poster's STREAK card; omit when the
   * board has no recurring streak above 1 (`posterStreakLabel`).
   */
  streak?: string;
  /** Called when the user taps Done, presses Escape, or clicks the scrim. */
  onDismiss: () => void;
}

/**
 * Modal sheet for sharing a Bingo or Greenlog story poster.
 *
 * Presents a `SharePoster` card (the rasterisation target), a "Show task names"
 * toggle (default on) and two action buttons:
 *   - **Share** - Web Share API with the PNG file (mobile/Edge); download fallback
 *     on desktop or browsers without `navigator.canShare`.
 *   - **Save image** - always triggers a PNG download via `<a download>`.
 *
 * Font embedding: `html-to-image` inlines `@font-face` rules from
 * `document.styleSheets` (Bricolage Grotesque / Archivo from Google Fonts);
 * cannot be verified headlessly - mark for human browser QA.
 *
 * Deliberate divergences from iOS `ShareBoardSheet`: no "Copy link" row (boards
 * have no shareable URL on web) and no per-app targets (the Web Share API's
 * native sheet handles destinations).
 *
 * Accessibility: `role="dialog"` + `useModalA11y` (aria-modal, Escape-to-close,
 * initial focus, Tab trap, focus restore).
 */
export function ShareBoardSheet({
  kind,
  boardName,
  boardSize,
  cells,
  completedTasks,
  totalTasks,
  linesCompleted,
  streak,
  onDismiss,
}: ShareBoardSheetProps): React.ReactElement {
  const posterRef = useRef<HTMLDivElement>(null);
  const [showLabels, setShowLabels] = useState(true);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  // ── Toast auto-dismiss (2.5 s — mirrors iOS cadence) ───────────────────
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 2500);
    return () => clearTimeout(t);
  }, [toast]);

  // ── aria-modal, Escape → dismiss, initial focus, Tab trap, focus restore ──
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: onDismiss,
  });

  // ── Rasterise the poster to a PNG Blob ─────────────────────────────────

  /**
   * Renders the poster node at 2× resolution via html-to-image.
   *
   * `html-to-image` auto-inlines `@font-face` declarations from
   * `document.styleSheets` — including Bricolage Grotesque / Archivo loaded from
   * Google Fonts — so the exported PNG uses the correct typeface. Font-file URLs
   * on `fonts.gstatic.com` carry `Access-Control-Allow-Origin: *`.
   *
   * @returns A PNG `Blob`, or `null` on failure.
   */
  const renderBlob = useCallback(async (): Promise<Blob | null> => {
    if (!posterRef.current) return null;
    try {
      const blob = await toBlob(posterRef.current, {
        pixelRatio: 2,   // 2× resolution for the 236 × 420 story card → 472 × 840 output
        skipFonts: false, // embed fonts (default; explicit for clarity)
      });
      return blob;
    } catch (err) {
      console.error('[ShareBoardSheet] html-to-image render failed:', err);
      return null;
    }
  }, []);

  // ── Share action ────────────────────────────────────────────────────────

  const handleShare = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    try {
      const blob = await renderBlob();
      if (!blob) {
        setToast('Could not render poster — try again.');
        return;
      }
      const file = new File([blob], shareFilename(boardName, kind), {
        type: 'image/png',
      });

      if (navigator.canShare?.({ files: [file] })) {
        // Web Share API with files (mobile Chrome/Safari, Edge on Windows 10+).
        // Requires HTTPS + a user-gesture — both are satisfied here (button click).
        await navigator.share({
          files: [file],
          title: shareTitle(boardName, kind),
          text: shareText(kind, boardName, linesCompleted, boardSize),
        });
        // Note: share was accepted — no success toast (the OS share sheet is feedback)
      } else {
        // Fallback for desktop browsers without Web Share file support.
        triggerDownload(blob, shareFilename(boardName, kind));
        setToast('Poster saved!');
      }
    } catch (err: unknown) {
      // AbortError = user cancelled the Web Share sheet — not an error worth reporting
      if (!(err instanceof Error && err.name === 'AbortError')) {
        setToast('Something went wrong — try again.');
      }
    } finally {
      setBusy(false);
    }
  }, [busy, renderBlob, boardName, kind, linesCompleted, boardSize]);

  // ── Save image action ───────────────────────────────────────────────────

  const handleSaveImage = useCallback(async () => {
    if (busy) return;
    setBusy(true);
    try {
      const blob = await renderBlob();
      if (!blob) {
        setToast('Could not render poster — try again.');
        return;
      }
      triggerDownload(blob, shareFilename(boardName, kind));
      setToast('Poster saved!');
    } finally {
      setBusy(false);
    }
  }, [busy, renderBlob, boardName, kind]);

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div
      className={styles.scrim}
      onClick={(e) => {
        // Dismiss when clicking the scrim itself, not its children
        if (e.target === e.currentTarget) onDismiss();
      }}
    >
      <div
        ref={modalRef}
        className={styles.sheet}
        role="dialog"
        aria-label={shareSheetTitle(kind)}
        {...modalProps}
      >
        {/* Sheet header */}
        <div className={styles.header}>
          <span className={styles.headerTitle}>{shareSheetTitle(kind)}</span>
          <button type="button" className={styles.doneBtn} onClick={onDismiss} aria-label="Done">
            Done
          </button>
        </div>

        {/* Scrollable body */}
        <div className={styles.body}>
          {/*
           * Poster wrapped in the keyline + hard-shadow elevation frame.
           * The inner `posterRef` div is the actual rasterisation target:
           * calling `toBlob(posterRef.current)` captures just the poster card
           * without the elevation border — matching iOS's `ImageRenderer` which
           * also renders `posterCard(...)` (no overlay shadow).
           */}
          <div className={styles.posterWrap}>
            <div className={styles.posterElevated}>
              <SharePoster
                ref={posterRef}
                kind={kind}
                boardName={boardName}
                boardSize={boardSize}
                cells={cells}
                completedTasks={completedTasks}
                totalTasks={totalTasks}
                streak={streak}
                showLabels={showLabels}
              />
            </div>
          </div>

          {/* Show task names toggle — mirrors iOS RisoInkSwitch */}
          <button
            type="button"
            className={styles.toggleRow}
            onClick={() => setShowLabels((v) => !v)}
            aria-pressed={showLabels}
            aria-label="Show task names"
          >
            <span
              className={`${styles.inkSwitch} ${showLabels ? styles.switchOn : ''}`}
              aria-hidden="true"
            >
              <span className={styles.switchKnob} />
            </span>
            <span className={styles.toggleLabel}>Show task names</span>
          </button>

          {/* Action buttons */}
          <div className={styles.actions}>
            <RisoButton
              kind="primary"
              size="large"
              fullWidth
              icon={<RisoIcon name="share" size={16} />}
              onClick={handleShare}
              disabled={busy}
              aria-label="Share poster image"
            >
              {busy ? 'Working…' : 'Share'}
            </RisoButton>
            <RisoButton
              kind="neutral"
              size="large"
              fullWidth
              onClick={handleSaveImage}
              disabled={busy}
              aria-label="Save poster as image"
            >
              Save image
            </RisoButton>
          </div>
        </div>

        {/* Transient toast — success / error feedback */}
        {toast && (
          <div className={styles.toast} role="status" aria-live="polite">
            {toast}
          </div>
        )}
      </div>
    </div>
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Triggers a browser PNG download for the given blob via a transient `<a>`.
 * The object URL is revoked after 1 s to allow the browser to initiate the
 * download before the reference is freed.
 */
function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
