import fs from 'fs';
import path from 'path';
import { normalizePlacementFields, withNormalizedPlacementFields } from '../../src/algorithms/placementFields';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'placementFieldsVectors.json'), 'utf8')
);

describe('normalizePlacementFields (fixture-driven, placementFieldsVectors.json)', () => {
  it('fixture is non-trivial', () => {
    expect(V.vectors.length).toBeGreaterThanOrEqual(10);
  });

  it.each(V.vectors as any[])('$name', (v: any) => {
    const out = normalizePlacementFields(v.input);
    // Dropped fields are absent (undefined), never null.
    const compact = JSON.parse(JSON.stringify(out));
    expect(compact).toEqual(v.expected);
  });

  it('withNormalizedPlacementFields removes dropped keys and keeps every other field', () => {
    const row = { id: 'bt', row: 1, targetKind: 'discrete', titleOverride: '  ', childTargets: [] } as any;
    const out = withNormalizedPlacementFields(row);
    expect(out).toEqual({ id: 'bt', row: 1 });
    expect('targetKind' in out).toBe(false);
  });
});
