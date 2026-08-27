import { useEffect, useState } from 'react';
import { ErrorCode, PurchasesError, type Package } from '@revenuecat/purchases-js';
import { useAuth } from '../../firebase/useAuth';
import { useEntitlement } from '../../hooks/useEntitlement';
import {
  getWebOfferings,
  isRevenueCatAvailable,
  purchaseWebPackage,
} from '../../entitlement/revenueCat';
import { UpgradeModal } from '../signedOut/UpgradeModal';
import { RisoButton } from '../riso';
import soStyles from '../signedOut/SignedOut.module.css';
import styles from './ProPaywall.module.css';

/** Terms/Privacy links required on the paywall (App Store 3.1.2). */
const TERMS_URL = 'https://oybc.com/terms';
const PRIVACY_URL = 'https://oybc.com/privacy';

/** What Pro unlocks — kept in sync with the shared proGating model. */
const PRO_BENEFITS = [
  'Unlimited boards',
  'Recurring & core boards (daily, weekly, monthly, yearly)',
  'Achievement & compound tasks',
];

export interface ProPaywallProps {
  /** Dismiss the paywall. */
  onClose: () => void;
}

/**
 * The Pro paywall (docs/MONETIZATION.md). Renders the current RevenueCat offering
 * (monthly / yearly / lifetime + the 7-day trial) via RevenueCat Web Billing's
 * hosted checkout. Purchasing requires a real account — a guest is routed through
 * the existing upgrade flow first, after which the plans become purchasable.
 */
export function ProPaywall({ onClose }: ProPaywallProps): React.ReactElement {
  const { isAnonymous } = useAuth();
  const { isPro } = useEntitlement();
  const [packages, setPackages] = useState<Package[] | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showUpgrade, setShowUpgrade] = useState(false);

  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    if (!isRevenueCatAvailable()) {
      setPackages([]);
      return;
    }
    getWebOfferings()
      .then((offerings) => {
        if (!cancelled) setPackages(offerings?.current?.availablePackages ?? []);
      })
      .catch(() => {
        if (!cancelled) {
          setPackages([]);
          setError('Couldn’t load plans. Please try again.');
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleBuy(pkg: Package): Promise<void> {
    // Purchasing requires a real account — send guests through upgrade first.
    if (isAnonymous) {
      setShowUpgrade(true);
      return;
    }
    if (busyId) return;
    setError(null);
    setBusyId(pkg.identifier);
    try {
      await purchaseWebPackage(pkg);
      onClose(); // isPro flips via the entitlements listener / RC cache
    } catch (err) {
      if (err instanceof PurchasesError && err.errorCode === ErrorCode.UserCancelledError) {
        // User backed out — no error UI.
      } else {
        setError('That didn’t go through. Please try again.');
      }
    } finally {
      setBusyId(null);
    }
  }

  if (showUpgrade) {
    // After a successful upgrade, isAnonymous flips false and the plans below
    // become purchasable; closing the upgrade returns here either way.
    return <UpgradeModal onClose={() => setShowUpgrade(false)} />;
  }

  return (
    <div className={soStyles.soAuthScrim} onClick={busyId ? undefined : onClose} role="presentation">
      <div
        className={soStyles.soAuthCard}
        role="dialog"
        aria-modal="true"
        aria-label="OYBC Pro"
        onClick={(e) => e.stopPropagation()}
      >
        {!busyId && (
          <button type="button" className={soStyles.soAuthX} onClick={onClose} aria-label="Close">
            ✕
          </button>
        )}

        <div className={soStyles.soKicker}>OYBC Pro</div>
        <div className={soStyles.soAuthH}>{isPro ? 'You’re on Pro 🎉' : 'Unlock everything.'}</div>

        {isPro ? (
          <>
            <p className={soStyles.soAuthP}>
              Thanks for supporting OYBC — every Pro feature is unlocked on all your devices.
            </p>
            <div className={soStyles.soConfirmActions}>
              <RisoButton kind="primary" onClick={onClose}>
                Done
              </RisoButton>
            </div>
          </>
        ) : (
          <>
            <ul className={styles.benefits}>
              {PRO_BENEFITS.map((b) => (
                <li key={b} className={styles.benefit}>
                  <span aria-hidden className={styles.benefitTick}>
                    ✓
                  </span>
                  {b}
                </li>
              ))}
            </ul>

            {isAnonymous && (
              <p className={soStyles.soAuthP}>Create a free account to subscribe — your boards come with you.</p>
            )}

            {error && <div className={soStyles.soError}>{error}</div>}

            <div className={styles.plans}>
              {packages === null ? (
                <p className={soStyles.soAuthP}>Loading plans…</p>
              ) : packages.length === 0 ? (
                <p className={soStyles.soAuthP}>Plans are unavailable right now. Please try again later.</p>
              ) : (
                packages.map((pkg) => {
                  const product = pkg.webBillingProduct;
                  return (
                    <RisoButton
                      key={pkg.identifier}
                      kind="primary"
                      size="large"
                      fullWidth
                      disabled={Boolean(busyId)}
                      onClick={() => void handleBuy(pkg)}
                    >
                      {busyId === pkg.identifier
                        ? 'Please wait…'
                        : `${product.title} · ${product.currentPrice.formattedPrice}`}
                    </RisoButton>
                  );
                })
              )}
            </div>

            <p className={styles.legal}>
              Subscriptions renew automatically until cancelled. By continuing you agree to our{' '}
              <a href={TERMS_URL} target="_blank" rel="noreferrer">
                Terms
              </a>{' '}
              and{' '}
              <a href={PRIVACY_URL} target="_blank" rel="noreferrer">
                Privacy Policy
              </a>
              .
            </p>
          </>
        )}
      </div>
    </div>
  );
}
