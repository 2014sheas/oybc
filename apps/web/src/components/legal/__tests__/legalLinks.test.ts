import { describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { LEGAL_LINKS } from '@oybc/shared';

// CI has no `.env.local`: the sign-in modal reads `useAuth()`, which reaches
// `firebase/config` and throws outside an AuthProvider — stub both.
vi.mock('../../../firebase/config', () => ({ auth: {}, firestore: {} }));
vi.mock('../../../firebase/useAuth', () => ({
  useAuth: () => ({
    signIn: async () => {},
    signUp: async () => {},
    signInWithGoogle: async () => {},
    signInWithApple: async () => {},
    signInAnonymously: async () => {},
  }),
}));

import { LegalLinksCard } from '../LegalLinksCard';
import { LegalLinksFooter } from '../LegalLinksFooter';
import { HelpPage } from '../../../pages/HelpPage';
import { SignInModal } from '../../signedOut/SignInModal';
import { SignedOutHome } from '../../signedOut/SignedOutHome';

const noop = (): void => {};

/** Every `<a …>` opening tag whose href is `url`. */
function anchorsTo(html: string, url: string): string[] {
  return html.match(new RegExp(`<a\\b[^>]*href="${url.replace(/[.]/g, '\\.')}"[^>]*>`, 'g')) ?? [];
}

/** Rendered markup of `element` (wrapped in a router for pages that link). */
function render(element: React.ReactElement): string {
  return renderToStaticMarkup(React.createElement(MemoryRouter, null, element));
}

const SURFACES: { name: string; element: () => React.ReactElement }[] = [
  { name: 'LegalLinksCard', element: () => React.createElement(LegalLinksCard) },
  { name: 'LegalLinksFooter', element: () => React.createElement(LegalLinksFooter) },
  { name: 'HelpPage', element: () => React.createElement(HelpPage) },
  {
    name: 'SignInModal',
    element: () =>
      React.createElement(SignInModal, { mode: 'signin', onClose: noop, onSwitchMode: noop }),
  },
  { name: 'SignedOutHome', element: () => React.createElement(SignedOutHome) },
];

describe('legal links', () => {
  it.each(SURFACES)('$name links every hosted legal document in a new tab', ({ element }) => {
    const html = render(element());
    for (const link of Object.values(LEGAL_LINKS)) {
      const anchors = anchorsTo(html, link.url);
      expect(anchors).toHaveLength(1);
      expect(anchors[0]).toContain('target="_blank"');
      expect(anchors[0]).toContain('rel="noopener noreferrer"');
      expect(html).toContain(`>${link.label}<`);
    }
  });

  it('lists the Privacy Policy before the Terms of Use', () => {
    const html = render(React.createElement(LegalLinksCard));
    expect(html.indexOf(LEGAL_LINKS.privacyPolicy.url)).toBeLessThan(
      html.indexOf(LEGAL_LINKS.termsOfUse.url)
    );
  });

  it('renders only the links it is given', () => {
    const html = render(
      React.createElement(LegalLinksFooter, { links: [LEGAL_LINKS.termsOfUse] })
    );
    expect(anchorsTo(html, LEGAL_LINKS.termsOfUse.url)).toHaveLength(1);
    expect(anchorsTo(html, LEGAL_LINKS.privacyPolicy.url)).toHaveLength(0);
    expect(html).not.toContain('·');
  });
});
