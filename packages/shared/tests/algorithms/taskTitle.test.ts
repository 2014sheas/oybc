import { generateCounterTaskTitle } from '../../src/algorithms/taskTitle';

describe('generateCounterTaskTitle', () => {
  it('returns auto-generated title when providedTitle is absent', () => {
    expect(generateCounterTaskTitle('Read', 100, 'pages')).toBe('Read 100 pages');
  });

  it('returns auto-generated title when providedTitle is an empty string', () => {
    expect(generateCounterTaskTitle('Run', 5, 'miles', '')).toBe('Run 5 miles');
  });

  it('falls back to formula when providedTitle is whitespace-only', () => {
    expect(generateCounterTaskTitle('Run', 5, 'miles', '   ')).toBe('Run 5 miles');
  });

  it('returns providedTitle when it is non-blank', () => {
    expect(generateCounterTaskTitle('Read', 100, 'pages', 'My Custom Title')).toBe('My Custom Title');
  });

  it('trims providedTitle when returning it', () => {
    expect(generateCounterTaskTitle('Read', 100, 'pages', '  Trimmed  ')).toBe('Trimmed');
  });

  it('trims action and unit with surrounding whitespace in formula', () => {
    expect(generateCounterTaskTitle('  Walk  ', 10, '  km  ')).toBe('Walk 10 km');
  });

  it('formats maxCount as integer when given a float', () => {
    expect(generateCounterTaskTitle('Read', 5.7, 'books')).toBe('Read 5 books');
  });

  it('handles maxCount of 1', () => {
    expect(generateCounterTaskTitle('Do', 1, 'pushup')).toBe('Do 1 pushup');
  });
});

describe('generateCounterTaskTitle — goal-less variant (pair-derived, R1)', () => {
  it('derives the pair-derived counter name when maxCount is null, eliding a default "Do"', () => {
    expect(generateCounterTaskTitle('Do', null, 'push-ups')).toBe('Push-ups');
  });

  it('renders the same when maxCount is undefined, with surrounding whitespace trimmed', () => {
    expect(generateCounterTaskTitle(' Do ', undefined, ' push-ups ')).toBe('Push-ups');
  });

  it('keeps a non-"Do" verb in the goal-less title', () => {
    expect(generateCounterTaskTitle('Run', null, 'miles')).toBe('Run miles');
  });

  it('keeps the numeric form when maxCount is present', () => {
    expect(generateCounterTaskTitle('Read', 100, 'pages')).toBe('Read 100 pages');
  });

  it('providedTitle still wins', () => {
    expect(generateCounterTaskTitle('Do', null, 'push-ups', 'My tally')).toBe('My tally');
  });
});
