import { STREAK_TIMEFRAMES, compactStreakLabel, totalLineCount, type BoardSize, type MomentKind, type Timeframe } from '@oybc/shared';

/** Which poster the sheet shares: the bingo moment's or the greenlog moment's. */
export type ShareKind = MomentKind;

/** The sheet's header title. */
export function shareSheetTitle(kind: ShareKind): string {
  return kind === 'bingo' ? 'Share bingo' : 'Share greenlog';
}

/** The poster's badge text. */
export function posterBadge(kind: ShareKind): string {
  return kind === 'bingo' ? 'BINGO' : 'GREENLOG';
}

/** Converts a board name to a safe filename slug. */
export function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}

/** `{slug}-bingo.png` / `{slug}-greenlog.png`. */
export function shareFilename(boardName: string, kind: ShareKind): string {
  return `${slugify(boardName) || 'board'}-${kind}.png`;
}

/** The native share sheet's title: "{board} — BINGO" / "{board} — GREENLOG". */
export function shareTitle(boardName: string, kind: ShareKind): string {
  return `${boardName} — ${posterBadge(kind)}`;
}

/** The native share sheet's text. */
export function shareText(kind: ShareKind, boardName: string, linesCompleted: number, boardSize: number): string {
  return kind === 'bingo'
    ? `Bingo on ${boardName}! ${linesCompleted} of ${totalLineCount(boardSize as BoardSize)} lines.`
    : 'I crushed every square. Greenlog on On Your Bingo Card!';
}

/**
 * The poster's STREAK card label, or `undefined` when the card is omitted: it
 * shows only on a CORE recurring-timeframe board with a streak above 1 (the moment
 * chip's rule).
 */
export function posterStreakLabel(streak: number, timeframe: Timeframe, isCore: boolean): string | undefined {
  if (!isCore || streak <= 1 || !(STREAK_TIMEFRAMES as readonly string[]).includes(timeframe)) return undefined;
  return compactStreakLabel(streak, timeframe);
}

/** Cell label font size in px: `clamp(6.5, 0.165 × cell, 14)`. */
export function posterLabelSize(cellPx: number): number {
  return Math.min(14, Math.max(6.5, 0.165 * cellPx));
}

/** The poster grid's side in px (inset content area). */
export const POSTER_GRID_PX = 196;
/** Gap between poster cells in px. */
export const POSTER_GAP_PX = 4;

/** One poster cell's side in px for a `size` × `size` board. */
export function posterCellPx(size: number): number {
  return (POSTER_GRID_PX - POSTER_GAP_PX * (size - 1)) / size;
}
