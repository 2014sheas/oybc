#!/usr/bin/env node
/**
 * check-coming-soon-tokens.mjs
 *
 * Detects value drift between the shared Riso design tokens
 * (packages/riso-tokens/riso.css) and the self-contained
 * apps/coming-soon stylesheet, which hand-copies the same token
 * VALUES under unprefixed custom-property names by design (see
 * apps/coming-soon/src/styles.css header + docs/COMING_SOON.md —
 * the placeholder intentionally has zero dependency on the app
 * build, so it can't just `import '@oybc/riso-tokens/riso.css'`).
 *
 * Parses the `--`-prefixed custom properties declared directly in
 * the light (`:root`) and dark/night-scheme blocks of both files,
 * strips the `riso-` prefix from packages/riso-tokens/riso.css's
 * names, and compares light-vs-light and dark-vs-dark. Fails
 * (exit 1) and lists mismatches if any token present in BOTH files'
 * corresponding block differs in value. Tokens present in only one
 * file (or only in one file's block) are ignored — the app has
 * tokens the placeholder doesn't need, and vice versa.
 *
 * No dependencies. Node >= 20. Run directly: `node scripts/check-coming-soon-tokens.mjs`
 *
 * Optional positional args (for local testing against a temp copy;
 * CI/normal usage passes none and uses the real repo paths):
 *   node scripts/check-coming-soon-tokens.mjs [risoTokensCssPath] [comingSoonCssPath]
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

const RISO_TOKENS_PATH = process.argv[2]
  ? resolve(process.argv[2])
  : resolve(repoRoot, 'packages/riso-tokens/riso.css');
const COMING_SOON_PATH = process.argv[3]
  ? resolve(process.argv[3])
  : resolve(repoRoot, 'apps/coming-soon/src/styles.css');

const RISO_PREFIX = 'riso-';

/** Strip /* ... *\/ comments so they never leak into parsed values. */
function stripComments(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, '');
}

/**
 * Extract the body of the FIRST block whose selector matches
 * `selectorRegex` (must have exactly one capture group for the
 * `{ ... }` body). Returns null if not found.
 *
 * Relies on these token blocks being flat property lists with no
 * nested braces, so matching up to the first `}` is safe.
 */
function extractBlock(css, selectorRegex) {
  const match = selectorRegex.exec(css);
  return match ? match[1] : null;
}

/** Parse `--name: value;` custom-property declarations from a block body. */
function parseCustomProps(blockText) {
  const props = new Map();
  if (!blockText) return props;
  const re = /--([a-zA-Z0-9-]+)\s*:\s*([^;]+);/g;
  let m;
  while ((m = re.exec(blockText)) !== null) {
    props.set(m[1], m[2].trim());
  }
  return props;
}

function stripRisoPrefix(map) {
  const out = new Map();
  for (const [key, value] of map) {
    const strippedKey = key.startsWith(RISO_PREFIX) ? key.slice(RISO_PREFIX.length) : key;
    out.set(strippedKey, value);
  }
  return out;
}

function loadRisoTokens(path) {
  const raw = stripComments(readFileSync(path, 'utf8'));
  const light = extractBlock(raw, /:root\s*\{([^}]*)\}/);
  const dark = extractBlock(raw, /\[data-theme=['"]dark['"]\]\s*\{([^}]*)\}/);
  return {
    light: stripRisoPrefix(parseCustomProps(light)),
    dark: stripRisoPrefix(parseCustomProps(dark)),
  };
}

function loadComingSoonTokens(path) {
  const raw = stripComments(readFileSync(path, 'utf8'));
  const light = extractBlock(raw, /:root\s*\{([^}]*)\}/);
  const dark = extractBlock(raw, /\.night\s*\{([^}]*)\}/);
  return {
    light: parseCustomProps(light),
    dark: parseCustomProps(dark),
  };
}

function diffTokens(risoMap, comingSoonMap, context) {
  const mismatches = [];
  let compared = 0;
  for (const [token, risoValue] of risoMap) {
    if (!comingSoonMap.has(token)) continue; // only in riso-tokens — ignored by design
    compared += 1;
    const comingSoonValue = comingSoonMap.get(token);
    if (comingSoonValue !== risoValue) {
      mismatches.push({ context, token, risoValue, comingSoonValue });
    }
  }
  return { mismatches, compared };
}

function main() {
  const riso = loadRisoTokens(RISO_TOKENS_PATH);
  const comingSoon = loadComingSoonTokens(COMING_SOON_PATH);

  const lightDiff = diffTokens(riso.light, comingSoon.light, 'light (:root)');
  const darkDiff = diffTokens(riso.dark, comingSoon.dark, 'dark (.night)');
  const mismatches = [...lightDiff.mismatches, ...darkDiff.mismatches];

  if (mismatches.length > 0) {
    console.error('Token drift detected between riso-tokens and apps/coming-soon:\n');
    for (const { context, token, risoValue, comingSoonValue } of mismatches) {
      console.error(
        `  [${context}] --${token}: riso-tokens="${risoValue}" coming-soon="${comingSoonValue}"`
      );
    }
    console.error(
      `\n${mismatches.length} mismatch(es). Update apps/coming-soon/src/styles.css to match ` +
        `packages/riso-tokens/riso.css, or document an intentional divergence in docs/COMING_SOON.md.`
    );
    process.exitCode = 1;
    return;
  }

  const checked = lightDiff.compared + darkDiff.compared;
  console.log(
    `Riso token drift-check passed: ${checked} shared token(s) compared against ` +
      `apps/coming-soon (tokens present in only one file are ignored), 0 mismatches.`
  );
}

main();
