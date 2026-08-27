import { useEffect, useState } from 'react';
import { doc, onSnapshot } from 'firebase/firestore';
import {
  DEFAULT_ENTITLEMENT,
  isEntitlementActive,
  mergeEntitlement,
  type Entitlement,
} from '@oybc/shared';
import { firestore } from '../firebase/config';
import { useAuth } from '../firebase/useAuth';
import { getWebCustomerInfo, isProFromCustomerInfo } from '../entitlement/revenueCat';

export interface UseEntitlementResult {
  /** The server-authoritative entitlement doc (or the free default). */
  entitlement: Entitlement;
  /** Effective Pro status for gating (UX only — never a security boundary). */
  isPro: boolean;
  /** True once the authority doc has resolved (or there's no signed-in user). */
  isReady: boolean;
}

/**
 * Reactive Pro status, mirroring `usePreferences`'s shape. Combines two signals
 * (docs/MONETIZATION.md — "authority vs. display"):
 *
 *  - **Authority:** a live `onSnapshot` on `entitlements/{uid}` (written only by
 *    the RevenueCat webhook), decoded through the tolerant `mergeEntitlement` and
 *    evaluated with the shared grace window via `isEntitlementActive`.
 *  - **Display fast-path:** RevenueCat's cached `CustomerInfo` (offline-capable),
 *    so a just-completed purchase or an offline session reflects Pro immediately.
 *
 * `isPro` is the OR of the two, so either granting source unlocks — and a briefly
 * stale/offline authority read never locks out a paying user.
 */
export function useEntitlement(): UseEntitlementResult {
  const { user } = useAuth();
  const uid = user?.id ?? null;

  const [entitlement, setEntitlement] = useState<Entitlement>(DEFAULT_ENTITLEMENT);
  const [rcActive, setRcActive] = useState(false);
  const [isReady, setIsReady] = useState(false);

  // Authority: the server-written entitlement doc, live.
  useEffect(() => {
    if (!uid) {
      setEntitlement(DEFAULT_ENTITLEMENT);
      setIsReady(true);
      return;
    }
    setIsReady(false);
    const unsub = onSnapshot(
      doc(firestore, 'entitlements', uid),
      (snap) => {
        setEntitlement(snap.exists() ? mergeEntitlement(snap.data() as Partial<Entitlement>) : DEFAULT_ENTITLEMENT);
        setIsReady(true);
      },
      () => {
        // Read error (e.g. rule not yet deployed / offline) — fall back to free
        // authority; the RC fast-path still applies.
        setEntitlement(DEFAULT_ENTITLEMENT);
        setIsReady(true);
      }
    );
    return unsub;
  }, [uid]);

  // Display fast-path: RevenueCat cached CustomerInfo.
  useEffect(() => {
    let cancelled = false;
    if (!uid) {
      setRcActive(false);
      return;
    }
    getWebCustomerInfo()
      .then((info) => {
        if (!cancelled) setRcActive(isProFromCustomerInfo(info));
      })
      .catch(() => {
        if (!cancelled) setRcActive(false);
      });
    return () => {
      cancelled = true;
    };
  }, [uid]);

  // Recompute Pro status in an effect (not during render — Date.now() is impure).
  // Re-runs whenever the authority doc or the RC cache changes; expiry/renewal
  // both arrive as an entitlement change, so the grace boundary is covered.
  const [isPro, setIsPro] = useState(false);
  useEffect(() => {
    setIsPro(rcActive || isEntitlementActive(entitlement, Date.now()));
  }, [entitlement, rcActive]);

  return { entitlement, isPro, isReady };
}
