import { useCallback, useEffect, useRef, useState } from 'react';
import { toBlob } from 'html-to-image';
import { SharePoster } from './SharePoster';
import { RisoButton, RisoIcon } from '../riso';
import styles from './ShareBoardSheet.module.css';

export interface ShareBoardSheetProps {
  boardName: string;
  completedTasks: number;
  totalTasks: number;
  linesCompleted: number;
  /**
   * Compact streak label e.g. "3d", "2w". Omit for non-core boards or a zero streak.
   * Presence shows the STREAK stat card on the poster; absence hides it.
   */
  streak?: string;
  /** Called when the user taps Done, presses Escape, or clicks the scrim. */
  onDismiss: () => void;
}

/**
 * Modal sheet for sharing the board's GREENLOG poster.
 *
 * Presents a `SharePoster` card (the rasterisation target), an "Include stats"
 * toggle, and two action buttons:
 *   - **Share** — Web Share API with the PNG file (mobile/Edge); download fallback
 *     on desktop or browsers without `navigator.canShare`.
 *   - **Save image** — always triggers a PNG download via `<a download>`.
 *
 * Font embedding: `html-to-image` walks `document.styleSheets` to find and
 * inline `@font-face` rules from the browser's loaded stylesheets (including the
 * Bricolage Grotesque / Archivo fonts from Google Fonts). The font files are
 * served from `fonts.gstatic.com` with `Access-Control-Allow-Origin: *`, so they
 * are fetchable at export time. Cannot be verified headlessly — mark for human
 * browser QA.
 *
 * Deliberate divergences from iOS `ShareBoardSheet`:
 *   - No "Copy link" row: boards have no shareable URL on web yet.
 *   - No icon-labelled Messages/Stories/More targets: the Web Share API's native
 *     share sheet handles destination selection.
 *
 * Accessibility: `role="dialog"` + `aria-modal="true"` + Escape-to-close.
 *
 * @param boardName - Board display name.
 * @param completedTasks - Squares completed.
 * @param totalTasks - Total squares.
 * @param linesCompleted - Bingo lines scored.
 * @param streak - Compact streak label. Omit to hide the STREAK stat on the poster.
 * @param onDismiss - Dismiss callback.
 */
export function ShareBoardSheet({
  boardName,
  completedTasks,
  totalTasks,
  linesCompleted,
  streak,
  onDismiss,
}: ShareBoardSheetProps): React.ReactElement {
  const posterRef = useRef<HTMLDivElement>(null);
  const [includeStats, setIncludeStats] = useState(true);
  const [busy, setBusy] = useState(false);
  const [toast, setToast] = useState<string | null>(null);

  // ── Toast auto-dismiss (2.5 s — mirrors iOS cadence) ───────────────────
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 2500);
    return () => clearTimeout(t);
  }, [toast]);

  // ── Escape key to dismiss ───────────────────────────────────────────────
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onDismiss();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onDismiss]);

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
        pixelRatio: 2,   // 2× resolution for the 280 px card → 560 px output
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
      const file = new File([blob], `${slugify(boardName)}-greenlog.png`, {
        type: 'image/png',
      });

      if (navigator.canShare?.({ files: [file] })) {
        // Web Share API with files (mobile Chrome/Safari, Edge on Windows 10+).
        // Requires HTTPS + a user-gesture — both are satisfied here (button click).
        await navigator.share({
          files: [file],
          title: `${boardName} — GREENLOG`,
          text: 'I crushed every square. GREENLOG on On Your Bingo Card!',
        });
        // Note: share was accepted — no success toast (the OS share sheet is feedback)
      } else {
        // Fallback for desktop browsers without Web Share file support.
        triggerDownload(blob, boardName);
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
  }, [busy, renderBlob, boardName]);

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
      triggerDownload(blob, boardName);
      setToast('Poster saved!');
    } finally {
      setBusy(false);
    }
  }, [busy, renderBlob, boardName]);

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div
      className={styles.scrim}
      onClick={(e) => {
        // Dismiss when clicking the scrim itself, not its children
        if (e.target === e.currentTarget) onDismiss();
      }}
    >
      <div className={styles.sheet} role="dialog" aria-modal="true" aria-label="Share board">
        {/* Sheet header */}
        <div className={styles.header}>
          <span className={styles.headerTitle}>Share board</span>
          <button type="button" className={styles.doneBtn} onClick={onDismiss} aria-label="Done">
            Done
          </button>
        </div>

        {/* Scrollable body */}
        <div className={styles.body}>
          {/*
           * Poster wrapped in the keyline + hard-shadow elevation frame.
           * The inner `posterRef` div is the actual rasterisation target:
           * calling `toBlob(posterRef.current)` captures just the blue card
           * without the elevation border — matching iOS's `ImageRenderer` which
           * also renders `posterCard(...)` (no overlay shadow).
           */}
          <div className={styles.posterWrap}>
            <div className={styles.posterElevated}>
              <SharePoster
                ref={posterRef}
                boardName={boardName}
                completedTasks={completedTasks}
                totalTasks={totalTasks}
                linesCompleted={linesCompleted}
                streak={streak}
                showStats={includeStats}
              />
            </div>
          </div>

          {/* Include stats toggle — mirrors iOS RisoInkSwitch */}
          <button
            type="button"
            className={styles.toggleRow}
            onClick={() => setIncludeStats((v) => !v)}
            aria-pressed={includeStats}
            aria-label="Include stats on the card"
          >
            <span
              className={`${styles.inkSwitch} ${includeStats ? styles.switchOn : ''}`}
              aria-hidden="true"
            >
              <span className={styles.switchKnob} />
            </span>
            <span className={styles.toggleLabel}>Include stats on the card</span>
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
function triggerDownload(blob: Blob, boardName: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${slugify(boardName)}-greenlog.png`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Converts a board name to a safe filename slug. */
function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}
