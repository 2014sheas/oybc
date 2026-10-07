import { describe, expect, it } from 'vitest';
import { ledgerPill } from '../ledgerPill';

describe('ledgerPill', () => {
  it('continuous with a remembered amount logs it', () => {
    expect(ledgerPill({ name: 'Miles', unit: 'mi', countKind: 'continuous', defaultLogAmount: 3.1 }))
      .toEqual({ label: '+ Log 3.1', ariaLabel: 'Log 3.1 mi for Miles', opensDetail: false, amount: 3.1 });
  });
  it('duration labels without a unit', () => {
    expect(ledgerPill({ name: 'Practice', unit: 'guitar', countKind: 'duration', defaultLogAmount: 30 }))
      .toMatchObject({ label: '+ Log 30m', ariaLabel: 'Log 30m for Practice' });
  });
  it('a never-logged continuous counter opens Counter Detail', () => {
    expect(ledgerPill({ name: 'Miles', unit: 'mi', countKind: 'continuous', defaultLogAmount: null }))
      .toMatchObject({ label: '+ Log', opensDetail: true, ariaLabel: 'Log Miles' });
  });
  it('discrete is unchanged', () => {
    expect(ledgerPill({ name: 'Push-ups', unit: 'push-ups', countKind: 'discrete', defaultLogAmount: null }))
      .toEqual({ label: '+ Log', ariaLabel: 'Log 1 push-ups for Push-ups', opensDetail: false, amount: 1 });
  });
});
