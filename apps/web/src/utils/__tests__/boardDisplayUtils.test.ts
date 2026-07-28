import { describe, expect, it } from 'vitest';
import { BoardStatus, Timeframe } from '@oybc/shared';
import {
  isBoardExpired,
  isBoardExpiringSoon,
  getExpiryLabel,
  boardMatchesListFilter,
} from '../boardDisplayUtils';

/**
 * Regression: a CUSTOM-timeframe board with a user-specified end date must
 * behave like a timed board for expiry/display — it seals at that date too
 * (`isBoardSealable` only excludes INDEFINITE), so the display predicates must
 * agree. Only INDEFINITE / no-endDate boards are "never expired / No deadline".
 */
const iso = (msFromNow: number) => new Date(Date.now() + msFromNow).toISOString();
const DAY = 24 * 60 * 60 * 1000;

describe('boardDisplayUtils — custom boards honor their end date', () => {
  it('isBoardExpired: custom board past its end date is expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM, endDate: iso(-DAY) })).toBe(true);
  });

  it('isBoardExpired: custom board before its end date is not expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) })).toBe(false);
  });

  it('isBoardExpired: indefinite / no-endDate boards are never expired', () => {
    expect(isBoardExpired({ timeframe: Timeframe.INDEFINITE, endDate: iso(-DAY) })).toBe(false);
    expect(isBoardExpired({ timeframe: Timeframe.CUSTOM })).toBe(false);
  });

  it('getExpiryLabel: custom board shows a countdown, not "No deadline"', () => {
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) })).toBe('3 days left');
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM, endDate: iso(-DAY) })).toBe('Expired');
    // Genuinely open-ended boards still read "No deadline".
    expect(getExpiryLabel({ timeframe: Timeframe.INDEFINITE, endDate: iso(3 * DAY) })).toBe('No deadline');
    expect(getExpiryLabel({ timeframe: Timeframe.CUSTOM })).toBe('No deadline');
  });

  it('isBoardExpiringSoon: active custom board within 24h is expiring soon', () => {
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.CUSTOM, endDate: iso(12 * 60 * 60 * 1000) }),
    ).toBe(true);
    // …but not one still days out, and not an indefinite board.
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.CUSTOM, endDate: iso(3 * DAY) }),
    ).toBe(false);
    expect(
      isBoardExpiringSoon({ status: BoardStatus.ACTIVE, timeframe: Timeframe.INDEFINITE, endDate: iso(12 * 60 * 60 * 1000) }),
    ).toBe(false);
  });
});

/**
 * Boards-list filter-chip semantics (PR #372): "Completed" gathers every board
 * whose run is over — greenlogged (status) PLUS ACTIVE boards that are sealed
 * or expired (a sealed-but-incomplete board keeps status ACTIVE forever by the
 * F3 sealing rule). Mirrors iOS `boardMatchesListFilter` in
 * `TimeframeFormatting.swift` / `IndefiniteBoardTests`.
 */
describe('boardMatchesListFilter — chip classification', () => {
  const greenlogged = { status: BoardStatus.COMPLETED, timeframe: Timeframe.MONTHLY, endDate: iso(-DAY) };
  const sealedActive = {
    status: BoardStatus.ACTIVE,
    timeframe: Timeframe.MONTHLY,
    endDate: iso(-DAY),
    sealedAt: iso(-DAY / 2),
  };
  const expiredActive = { status: BoardStatus.ACTIVE, timeframe: Timeframe.CUSTOM, endDate: iso(-DAY) };
  const liveActive = { status: BoardStatus.ACTIVE, timeframe: Timeframe.MONTHLY, endDate: iso(3 * DAY) };
  const indefiniteActive = { status: BoardStatus.ACTIVE, timeframe: Timeframe.INDEFINITE };
  const staleDraft = { status: BoardStatus.DRAFT, timeframe: Timeframe.MONTHLY, endDate: iso(-DAY) };
  const archived = { status: BoardStatus.ARCHIVED, timeframe: Timeframe.MONTHLY, endDate: iso(-DAY) };
  const all = [greenlogged, sealedActive, expiredActive, liveActive, indefiniteActive, staleDraft, archived];

  it('Completed gathers every finished board: greenlogged + sealed + expired', () => {
    expect(boardMatchesListFilter(greenlogged, 'completed')).toBe(true);
    expect(boardMatchesListFilter(sealedActive, 'completed')).toBe(true);
    expect(boardMatchesListFilter(expiredActive, 'completed')).toBe(true);
  });

  it('Completed excludes in-play, draft, and archived boards', () => {
    expect(boardMatchesListFilter(liveActive, 'completed')).toBe(false);
    expect(boardMatchesListFilter(indefiniteActive, 'completed')).toBe(false);
    expect(boardMatchesListFilter(staleDraft, 'completed')).toBe(false);
    expect(boardMatchesListFilter(archived, 'completed')).toBe(false);
  });

  it('Active = still in play only (sealed/expired hidden)', () => {
    expect(boardMatchesListFilter(liveActive, 'active')).toBe(true);
    expect(boardMatchesListFilter(indefiniteActive, 'active')).toBe(true);
    expect(boardMatchesListFilter(sealedActive, 'active')).toBe(false);
    expect(boardMatchesListFilter(expiredActive, 'active')).toBe(false);
  });

  it('Draft is an exact status match; All passes everything through', () => {
    expect(boardMatchesListFilter(staleDraft, 'draft')).toBe(true);
    expect(boardMatchesListFilter(liveActive, 'draft')).toBe(false);
    for (const b of all) expect(boardMatchesListFilter(b, 'all')).toBe(true);
  });
});
