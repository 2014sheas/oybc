import { LEGAL_LINKS, type LegalLink } from '@oybc/shared';
import styles from './LegalLinks.module.css';

/** Every hosted legal document, in the order the apps list them. */
const ALL_LEGAL_LINKS: readonly LegalLink[] = Object.values(LEGAL_LINKS);

export interface LegalLinksCardProps {
  /** The links to list; defaults to every hosted legal document. */
  links?: readonly LegalLink[];
}

/**
 * A Riso card listing the hosted legal documents — "Privacy Policy",
 * "Terms of Use" — as rows that open the page in a new tab. Shown on
 * Settings and Help.
 *
 * iOS twin: `Views/Components/LegalLinksCard.swift`.
 *
 * @param props.links - Optional override of the listed links.
 * @returns The card element.
 */
export function LegalLinksCard({ links = ALL_LEGAL_LINKS }: LegalLinksCardProps): React.ReactElement {
  return (
    <div className={styles.card}>
      {links.map((link) => (
        <a
          key={link.url}
          href={link.url}
          target="_blank"
          rel="noopener noreferrer"
          className={styles.row}
        >
          <span className={styles.rowLabel}>{link.label}</span>
          <span className={styles.rowArrow} aria-hidden="true">
            ↗
          </span>
        </a>
      ))}
    </div>
  );
}
