import { useLiveQuery } from 'dexie-react-hooks';
import { loadCountsTowardSection, type CountsTowardSectionData } from '../db/operations/countsTowardSection';

/**
 * Live rows for Counter Detail's "Counts toward" section.
 *
 * @param counterId - The counter root (undefined while the route resolves).
 * @returns The section data, or `undefined` until the first read lands.
 */
export function useCountsTowardSection(counterId: string | undefined): CountsTowardSectionData | undefined {
  return useLiveQuery(() => (counterId ? loadCountsTowardSection(counterId) : undefined), [counterId]);
}
