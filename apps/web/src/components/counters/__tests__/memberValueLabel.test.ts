import { describe, expect, it } from 'vitest';
import { memberValueLabel, memberValueParts } from '../memberValueLabel';

describe('memberValueLabel', () => {
  it('groups discrete thousands', () => expect(memberValueLabel(512, 1000, 'discrete')).toBe('512/1,000'));
  it('continuous keeps decimals', () => expect(memberValueLabel(12.4, 26.2, 'continuous')).toBe('12.4/26.2'));
  it('duration reads h:m', () => expect(memberValueLabel(270, 630, 'duration')).toBe('4h 30m/10h 30m'));
  it('parts split the two sides', () => expect(memberValueParts(512, 1000, 'discrete')).toEqual({ logged: '512', goal: '1,000' }));
});
