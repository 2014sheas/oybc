import {
  canCoalesceSyncOwners,
  isForeignOwnedSyncItem,
} from '../../src/constants';
import { SyncQueueItemSchema } from '../../src/validation';
import { SyncOperationType, SyncStatus } from '../../src/constants/enums';

describe('isForeignOwnedSyncItem', () => {
  it('flags an item stamped with a different uid', () => {
    expect(isForeignOwnedSyncItem('anon-uid', 'real-uid')).toBe(true);
  });

  it('keeps an item stamped with the pushing uid', () => {
    expect(isForeignOwnedSyncItem('real-uid', 'real-uid')).toBe(false);
  });

  it('keeps legacy unstamped items (null and absent)', () => {
    expect(isForeignOwnedSyncItem(null, 'real-uid')).toBe(false);
    expect(isForeignOwnedSyncItem(undefined, 'real-uid')).toBe(false);
  });
});

describe('canCoalesceSyncOwners', () => {
  it('coalesces within one owner', () => {
    expect(canCoalesceSyncOwners('a', 'a')).toBe(true);
  });

  it('never coalesces across owners', () => {
    expect(canCoalesceSyncOwners('a', 'b')).toBe(false);
  });

  it('never folds an unowned op into a stamped row', () => {
    expect(canCoalesceSyncOwners('a', null)).toBe(false);
    expect(canCoalesceSyncOwners('a', undefined)).toBe(false);
  });

  it('lets any op adopt a legacy unstamped row', () => {
    expect(canCoalesceSyncOwners(null, 'a')).toBe(true);
    expect(canCoalesceSyncOwners(undefined, undefined)).toBe(true);
  });
});

describe('SyncQueueItemSchema ownerUid', () => {
  const base = {
    id: '11111111-1111-4111-8111-111111111111',
    entityType: 'boardTasks',
    entityId: '22222222-2222-4222-8222-222222222222',
    operationType: SyncOperationType.CREATE,
    payload: '{}',
    status: SyncStatus.PENDING,
    retryCount: 0,
    createdAt: '2026-09-24T00:00:00.000Z',
    priority: 0,
  };

  it('accepts a stamped, a null and an absent owner', () => {
    expect(SyncQueueItemSchema.safeParse({ ...base, ownerUid: 'u1' }).success).toBe(true);
    expect(SyncQueueItemSchema.safeParse({ ...base, ownerUid: null }).success).toBe(true);
    expect(SyncQueueItemSchema.safeParse(base).success).toBe(true);
  });

  it('rejects a non-string owner', () => {
    expect(SyncQueueItemSchema.safeParse({ ...base, ownerUid: 42 }).success).toBe(false);
  });
});
