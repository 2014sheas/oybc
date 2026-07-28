import * as fs from 'fs';
import * as path from 'path';
import { resolveConflict, type SyncableEntity } from '../../src/algorithms/lwwResolve';

/**
 * Runs the hand-authored cross-platform vector fixture
 * (`tests/fixtures/lwwVectors.json`) through the shared `resolveConflict`.
 * The SAME fixture is exercised on the iOS side by
 * `apps/ios/OYBCTests/LwwVectorTests.swift` against `SyncService.swift`'s
 * Swift mirror — both suites passing is what proves the two
 * implementations agree.
 */

interface LwwVector {
  name: string;
  localVersion: number;
  localUpdatedAt: string;
  remoteVersion: number;
  remoteUpdatedAt: string;
  winner: 'local' | 'remote';
}

const FIXTURE_PATH = path.join(__dirname, '../fixtures/lwwVectors.json');
const IOS_COPY_PATH = path.join(
  __dirname,
  '../../../../apps/ios/OYBCTests/Fixtures/lwwVectors.json',
);
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8')) as { vectors: LwwVector[] };

function toEntity(version: number, updatedAt: string): SyncableEntity {
  return { id: 'x', version, updatedAt, isDeleted: false };
}

describe('resolveConflict — cross-platform LWW vectors', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  it.each(fixture.vectors.map((v) => [v.name, v] as const))('%s', (_name, vector) => {
    const local = toEntity(vector.localVersion, vector.localUpdatedAt);
    const remote = toEntity(vector.remoteVersion, vector.remoteUpdatedAt);
    const result = resolveConflict(local, remote);
    expect(result.winner).toBe(vector.winner);
  });
});

describe('lwwVectors iOS bundle copy', () => {
  // Same story as syncContract.json — xcodegen can't bundle a resource
  // from outside apps/ios, so apps/ios/OYBCTests/Fixtures/lwwVectors.json
  // is a checked-in copy that LwwVectorTests.swift reads. This fixture is
  // hand-authored (not script-generated), so unlike syncContract.json
  // there's no `gen:sync-contract` step to keep the two in lockstep —
  // copy both by hand when editing vectors. This test is the guard rail:
  // if you edit one without the other, it fails here.
  it('is byte-identical to tests/fixtures/lwwVectors.json', () => {
    expect(fs.existsSync(IOS_COPY_PATH)).toBe(true);
    const canonical = fs.readFileSync(FIXTURE_PATH, 'utf8');
    const iosCopy = fs.readFileSync(IOS_COPY_PATH, 'utf8');
    expect(iosCopy).toEqual(canonical);
  });
});
