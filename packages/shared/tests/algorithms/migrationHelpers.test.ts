import {
  migrationDefaultPoolToPoolId,
  migrationDefaultPoolToCoreBoardDefaultId,
  migrationTemplateToPoolId,
} from '../../src/algorithms/migrationHelpers';

// ─── P1 migration mint ids (review finding C2) ────────────────────────────
//
// docs/POOLS_RECURRING.md §Migration. These must be pure + deterministic:
// same source id in → same minted id out, every time, on every platform.

describe('migrationDefaultPoolToPoolId / migrationDefaultPoolToCoreBoardDefaultId / migrationTemplateToPoolId', () => {
  it('is deterministic — same source id always derives the same minted id', () => {
    expect(migrationDefaultPoolToPoolId('dp-1')).toBe(migrationDefaultPoolToPoolId('dp-1'));
    expect(migrationDefaultPoolToCoreBoardDefaultId('dp-1')).toBe(
      migrationDefaultPoolToCoreBoardDefaultId('dp-1'),
    );
    expect(migrationTemplateToPoolId('tmpl-1')).toBe(migrationTemplateToPoolId('tmpl-1'));
  });

  it('the three mint sites never collide with each other for the same source id', () => {
    const poolId = migrationDefaultPoolToPoolId('shared-id');
    const coreDefaultId = migrationDefaultPoolToCoreBoardDefaultId('shared-id');
    const templatePoolId = migrationTemplateToPoolId('shared-id');
    expect(new Set([poolId, coreDefaultId, templatePoolId]).size).toBe(3);
  });

  it('different source ids derive different minted ids', () => {
    expect(migrationDefaultPoolToPoolId('dp-a')).not.toBe(migrationDefaultPoolToPoolId('dp-b'));
  });

  // Cross-platform pin: this exact literal is asserted BYTE-IDENTICAL in the
  // iOS XCTest suite (`OYBCTests/PoolsCoreBoardDefaultsMigrationTests.swift`,
  // `test_deterministicMintIds_matchCrossPlatformFixture`) AND in the web
  // Vitest suite (`apps/web/src/db/operations/__tests__/migrationV16.test.ts`,
  // "derives the exact fixture id..."). If this literal ever needs to
  // change, update all three in the same PR — the whole point of uuidv5
  // here is that both platforms derive the identical id from the identical
  // source id, given byte-identical namespace strings.
  it('derives the exact fixture ids for the locked cross-platform vector', () => {
    expect(migrationDefaultPoolToPoolId('dp-fixture-1')).toBe(
      'e1105aeb-04bc-58ca-936c-be32ea86437b',
    );
    expect(migrationDefaultPoolToCoreBoardDefaultId('dp-fixture-1')).toBe(
      '94e67c0c-b1d1-50f6-90ab-6cedf9e60efc',
    );
    expect(migrationTemplateToPoolId('tmpl-fixture-1')).toBe(
      'f11ff2bb-283e-5867-8348-253dc1fe46db',
    );
  });
});
