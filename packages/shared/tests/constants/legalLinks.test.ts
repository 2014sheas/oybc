import * as fs from 'fs';
import * as path from 'path';
import { LEGAL_LINKS } from '../../src/constants/legalLinks';

/**
 * The in-app legal links must land on a real page. The pages are static
 * files in `apps/coming-soon`, built as Vite inputs and served at clean URLs by
 * Firebase Hosting — and every unknown path on oybc.com falls through the
 * `**` catch-all to the Coming Soon poster, so a broken link would never 404:
 * it would silently show the wrong page. These checks pin the whole chain.
 */
const REPO_ROOT = path.join(__dirname, '../../../..');
const COMING_SOON_DIR = path.join(REPO_ROOT, 'apps/coming-soon');

const links = Object.values(LEGAL_LINKS);

describe('LEGAL_LINKS', () => {
  it.each(links)('$label is an https URL on the oybc.com apex with one path segment', (link) => {
    const url = new URL(link.url);
    expect(url.protocol).toBe('https:');
    expect(url.host).toBe('oybc.com');
    expect(url.pathname).toMatch(/^\/[a-z-]+$/);
    expect(url.search).toBe('');
    expect(url.hash).toBe('');
  });

  it('gives every link a distinct label and URL', () => {
    expect(new Set(links.map((l) => l.label)).size).toBe(links.length);
    expect(new Set(links.map((l) => l.url)).size).toBe(links.length);
  });

  it.each(links)('$label has a built page in apps/coming-soon', (link) => {
    const page = `${new URL(link.url).pathname.slice(1)}.html`;
    expect(fs.existsSync(path.join(COMING_SOON_DIR, page))).toBe(true);
    const viteConfig = fs.readFileSync(path.join(COMING_SOON_DIR, 'vite.config.ts'), 'utf8');
    expect(viteConfig).toContain(`'${page}'`);
  });

  it('is served at clean URLs by Firebase Hosting', () => {
    const firebase = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'firebase.json'), 'utf8'));
    expect(firebase.hosting.public).toBe('apps/coming-soon/dist');
    expect(firebase.hosting.cleanUrls).toBe(true);
    // No explicit rewrite may claim a legal path ahead of the static file.
    const sources: string[] = (firebase.hosting.rewrites ?? []).map(
      (r: { source: string }) => r.source
    );
    for (const link of links) {
      expect(sources).not.toContain(new URL(link.url).pathname);
    }
  });
});
