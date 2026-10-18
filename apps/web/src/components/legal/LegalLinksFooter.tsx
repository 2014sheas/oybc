import { Fragment } from 'react';
import { LEGAL_LINKS, type LegalLink } from '@oybc/shared';
import styles from './LegalLinks.module.css';

/** Every hosted legal document, in the order the apps list them. */
const ALL_LEGAL_LINKS: readonly LegalLink[] = Object.values(LEGAL_LINKS);

export interface LegalLinksFooterProps {
  /** The links to show; defaults to every hosted legal document. */
  links?: readonly LegalLink[];
}

/**
 * The hosted legal documents as one quiet line of links —
 * "Privacy Policy · Terms of Use" — for the bottom of the sign-in modal.
 * Each opens its page in a new tab.
 *
 * iOS twin: `Views/Components/LegalLinksFooter.swift`.
 *
 * @param props.links - Optional override of the shown links.
 * @returns The footer element.
 */
export function LegalLinksFooter({ links = ALL_LEGAL_LINKS }: LegalLinksFooterProps): React.ReactElement {
  return (
    <nav className={styles.footer} aria-label="Legal">
      {links.map((link, index) => (
        <Fragment key={link.url}>
          {index > 0 && <span aria-hidden="true">·</span>}
          <a href={link.url} target="_blank" rel="noopener noreferrer">
            {link.label}
          </a>
        </Fragment>
      ))}
    </nav>
  );
}
