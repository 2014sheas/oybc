import { describe, expect, it } from 'vitest';
import { memberValueParts } from '../memberValueLabel';

describe('memberValueParts', () => {
  it('groups discrete thousands', () => expect(memberValueParts(512, 1000, 'discrete')).toEqual({ logged: '512', goal: '1,000' }));
  it('continuous keeps decimals', () => expect(memberValueParts(12.4, 26.2, 'continuous')).toEqual({ logged: '12.4', goal: '26.2' }));
  it('duration reads h:m', () => expect(memberValueParts(270, 630, 'duration')).toEqual({ logged: '4h 30m', goal: '10h 30m' }));
});
