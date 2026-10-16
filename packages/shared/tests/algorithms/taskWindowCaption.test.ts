import { Timeframe, TaskType } from '../../src/constants/enums';
import { taskWindowCaptionLines } from '../../src/algorithms/taskWindowCaption';

const now = new Date('2026-10-16T17:30:00.000Z');
const counting = { type: TaskType.COUNTING } as const;

describe('taskWindowCaptionLines', () => {
  it('is empty for a plain task with no window and no link', () => {
    expect(taskWindowCaptionLines({ type: TaskType.NORMAL, createdInWizard: false }, now)).toEqual([]);
  });

  it('names a daily window and marks it ended once now is past its end', () => {
    expect(
      taskWindowCaptionLines(
        { ...counting, timeframe: Timeframe.DAILY, startDate: '2026-10-13T00:00:00', endDate: '2026-10-13T23:59:59.999', createdInWizard: true },
        now,
      ),
    ).toEqual(['Window · Oct 13, 2026 · ended']);
  });

  it('a still-open window is not marked ended; an open-ended one never is', () => {
    expect(
      taskWindowCaptionLines({ ...counting, timeframe: Timeframe.MONTHLY, startDate: '2026-10-01T00:00:00', endDate: '2026-10-31T23:59:59.999', createdInWizard: false }, now),
    ).toEqual(['Window · October 2026']);
    expect(
      taskWindowCaptionLines({ ...counting, timeframe: Timeframe.INDEFINITE, startDate: '2026-02-15T00:00:00', createdInWizard: false }, now),
    ).toEqual(['Window · Ongoing']);
  });

  it('a custom or timeframe-less window shows its bare dates', () => {
    expect(
      taskWindowCaptionLines({ ...counting, timeframe: Timeframe.CUSTOM, startDate: '2026-10-01T00:00:00', endDate: '2026-10-20T23:59:59.999', createdInWizard: false }, now),
    ).toEqual(['Window · Oct 1, 2026 – Oct 20, 2026']);
    expect(taskWindowCaptionLines({ ...counting, startDate: '2026-10-01T00:00:00', createdInWizard: false }, now)).toEqual([
      'Window · Oct 1, 2026',
    ]);
  });

  it('a window-stamped linked counter is a per-window copy; a hub-linked one follows each board', () => {
    expect(
      taskWindowCaptionLines(
        { ...counting, sharedCounterId: 'root', timeframe: Timeframe.DAILY, startDate: '2026-10-13T00:00:00', endDate: '2026-10-13T23:59:59.999', createdInWizard: true },
        now,
      ),
    ).toEqual(['Window · Oct 13, 2026 · ended', 'Linked counter · per-window copy']);
    expect(taskWindowCaptionLines({ ...counting, sharedCounterId: 'root', createdInWizard: true }, now)).toEqual([
      "Linked counter · follows each board's window",
    ]);
  });

  it('the link line is counting-only', () => {
    expect(taskWindowCaptionLines({ type: TaskType.NORMAL, sharedCounterId: 'root', createdInWizard: false }, now)).toEqual([]);
  });
});
