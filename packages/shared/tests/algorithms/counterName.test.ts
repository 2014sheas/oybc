import { formatCounterName } from '../../src/algorithms/counterName';

describe('formatCounterName', () => {
  describe('derivation table', () => {
    it('elides the default "Do" verb, capitalizing the noun', () => {
      expect(formatCounterName('Do', 'push-ups')).toBe('Push-ups');
    });

    it('keeps a non-"Do" verb, capitalizing only the verb', () => {
      expect(formatCounterName('Run', 'miles')).toBe('Run miles');
    });

    it('keeps a non-"Do" verb for a second example', () => {
      expect(formatCounterName('Read', 'pages')).toBe('Read pages');
    });
  });

  describe('"Do" elision is case-insensitive', () => {
    it('elides lowercase "do"', () => {
      expect(formatCounterName('do', 'sit-ups')).toBe('Sit-ups');
    });

    it('elides uppercase "DO"', () => {
      expect(formatCounterName('DO', 'sit-ups')).toBe('Sit-ups');
    });

    it('elides mixed-case "dO"', () => {
      expect(formatCounterName('dO', 'sit-ups')).toBe('Sit-ups');
    });
  });

  describe('blank/null action backfills to "Do"', () => {
    it('treats an empty-string action as "Do"', () => {
      expect(formatCounterName('', 'burpees')).toBe('Burpees');
    });

    it('treats a whitespace-only action as "Do"', () => {
      expect(formatCounterName('   ', 'burpees')).toBe('Burpees');
    });

    it('treats a null action as "Do"', () => {
      expect(formatCounterName(null, 'burpees')).toBe('Burpees');
    });

    it('treats an undefined action as "Do"', () => {
      expect(formatCounterName(undefined, 'burpees')).toBe('Burpees');
    });
  });

  describe('trimming', () => {
    it('trims surrounding whitespace on both action and unit', () => {
      expect(formatCounterName('  Run  ', '  miles  ')).toBe('Run miles');
    });

    it('trims a "Do" verb before comparing case-insensitively', () => {
      expect(formatCounterName('  do  ', 'push-ups')).toBe('Push-ups');
    });
  });

  describe('empty/null noun', () => {
    it('falls back to "" when verb is "Do" and noun is blank', () => {
      expect(formatCounterName('Do', '')).toBe('');
    });

    it('falls back to "" when verb is "Do" and noun is null', () => {
      expect(formatCounterName('Do', null)).toBe('');
    });

    it('falls back to "" when both action and unit are blank/null/undefined', () => {
      expect(formatCounterName(null, null)).toBe('');
      expect(formatCounterName(undefined, undefined)).toBe('');
      expect(formatCounterName('', '')).toBe('');
    });

    it('returns the capitalized verb alone when non-"Do" and noun is blank', () => {
      expect(formatCounterName('Run', '')).toBe('Run');
    });

    it('returns the capitalized verb alone when non-"Do" and noun is null', () => {
      expect(formatCounterName('Run', null)).toBe('Run');
    });
  });

  describe('first-letter capitalization preserves the rest', () => {
    it('preserves internal casing of the noun (Do-elided branch)', () => {
      expect(formatCounterName('Do', 'push-UPs')).toBe('Push-UPs');
    });

    it('preserves internal casing of the verb', () => {
      expect(formatCounterName('rUN', 'miles')).toBe('RUN miles');
    });

    it('does not alter noun casing when verb is non-"Do"', () => {
      expect(formatCounterName('Read', 'PAGES')).toBe('Read PAGES');
    });
  });
});
