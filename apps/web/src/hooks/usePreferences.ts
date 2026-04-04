import { useState, useCallback } from 'react';
import type { WeekStartDay } from '@oybc/shared';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * User preferences persisted to localStorage.
 *
 * These are UI preferences (not synced data), so localStorage is the right
 * storage layer — no DB table needed.
 */
export interface Preferences {
  weekStartDay: WeekStartDay;
}

// ─── Constants ────────────────────────────────────────────────────────────────

const PREFS_KEY = 'oybc-preferences';

const DEFAULTS: Preferences = {
  weekStartDay: 'monday',
};

// ─── Hook ─────────────────────────────────────────────────────────────────────

/**
 * React hook for reading and updating user preferences.
 *
 * Persists to localStorage as JSON. Returns the current preferences
 * and a setter that merges partial updates.
 *
 * @returns [preferences, updatePreferences]
 */
export function usePreferences(): [Preferences, (updates: Partial<Preferences>) => void] {
  const [prefs, setPrefs] = useState<Preferences>(() => {
    try {
      const stored = localStorage.getItem(PREFS_KEY);
      if (stored) {
        const parsed = JSON.parse(stored);
        return {
          weekStartDay:
            parsed.weekStartDay === 'monday' || parsed.weekStartDay === 'sunday'
              ? parsed.weekStartDay
              : DEFAULTS.weekStartDay,
        };
      }
    } catch {
      // Invalid JSON — fall through to defaults
    }
    return DEFAULTS;
  });

  const updatePreferences = useCallback((updates: Partial<Preferences>) => {
    setPrefs((prev) => {
      const next = { ...prev, ...updates };
      localStorage.setItem(PREFS_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  return [prefs, updatePreferences];
}
