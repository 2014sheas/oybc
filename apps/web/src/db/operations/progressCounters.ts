import { db } from '../database';
import type { ProgressCounter, CreateProgressCounterInput } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';

/**
 * ProgressCounter CRUD Operations
 */

/**
 * Fetch all progress counters for a user (excluding deleted)
 */
export async function fetchProgressCounters(userId: string): Promise<ProgressCounter[]> {
  return db.progressCounters
    .where('[userId+isDeleted]')
    .equals([userId, false] as any)
    .sortBy('name');
}

/**
 * Fetch a single progress counter by ID
 */
export async function fetchProgressCounter(
  id: string
): Promise<ProgressCounter | undefined> {
  return db.progressCounters.get(id);
}

/**
 * Create a new progress counter
 */
export async function createProgressCounter(
  userId: string,
  input: CreateProgressCounterInput
): Promise<ProgressCounter> {
  const counter: ProgressCounter = {
    id: generateUUID(),
    userId,
    name: input.name,
    unit: input.unit,
    targetValue: input.targetValue,
    currentValue: 0,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.progressCounters.add(counter);
  return counter;
}

/**
 * Update a progress counter
 */
export async function updateProgressCounter(
  id: string,
  updates: Partial<ProgressCounter>
): Promise<void> {
  await db.progressCounters.update(id, {
    ...updates,
    updatedAt: currentTimestamp(),
    version: db.progressCounters.get(id).then((c) => (c?.version ?? 0) + 1),
  });
}

/**
 * Increment a progress counter
 */
export async function incrementProgressCounter(
  id: string,
  amount: number
): Promise<void> {
  const counter = await db.progressCounters.get(id);
  if (!counter) return;

  await db.progressCounters.update(id, {
    currentValue: counter.currentValue + amount,
    updatedAt: currentTimestamp(),
    version: counter.version + 1,
  });
}

/**
 * Soft delete a progress counter
 */
export async function deleteProgressCounter(id: string): Promise<void> {
  await db.progressCounters.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
  });
}

/**
 * Reset a progress counter to zero
 */
export async function resetProgressCounter(id: string): Promise<void> {
  await db.progressCounters.update(id, {
    currentValue: 0,
    updatedAt: currentTimestamp(),
    version: db.progressCounters.get(id).then((c) => (c?.version ?? 0) + 1),
  });
}
