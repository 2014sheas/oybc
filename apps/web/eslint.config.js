// ESLint 10 flat config. Replaces the classic `.eslintrc.cjs`.
// Each entry in the exported array is a config object whose `files`
// field (if present) narrows which files it applies to.

import js from '@eslint/js';
import tsPlugin from '@typescript-eslint/eslint-plugin';
import tsParser from '@typescript-eslint/parser';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import globals from 'globals';

export default [
  // ─── Ignores ────────────────────────────────────────────────────────────────
  {
    ignores: ['dist/**', 'node_modules/**', '.turbo/**'],
  },

  // ─── JS base ────────────────────────────────────────────────────────────────
  js.configs.recommended,

  // ─── TS + React ─────────────────────────────────────────────────────────────
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaVersion: 2020,
        sourceType: 'module',
        ecmaFeatures: { jsx: true },
      },
      globals: {
        ...globals.browser,
        ...globals.es2020,
        // React types are referenced without an import (e.g.
        // `React.ReactElement` return annotations). TypeScript handles
        // the resolution; ESLint's `no-undef` doesn't see it, so list
        // `React` explicitly.
        React: 'readonly',
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    rules: {
      // Inherit @typescript-eslint's "recommended" ruleset
      ...tsPlugin.configs.recommended.rules,
      // Inherit react-hooks' "recommended" ruleset
      ...reactHooks.configs.recommended.rules,
      // TypeScript handles undefined-identifier checking; ESLint's
      // `no-undef` is redundant and produces false positives on type
      // references. Disabling is the standard advice for TS projects.
      'no-undef': 'off',
      // `react-hooks/set-state-in-effect` (new in v7) fires on patterns
      // we use deliberately (syncing local draft state from external
      // props). Re-evaluate during a dedicated hook-hygiene pass.
      'react-hooks/set-state-in-effect': 'off',
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
      '@typescript-eslint/no-unused-vars': [
        'warn',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      // ─── DB layering boundary (B3, issue #284) ────────────────────────────
      // The raw Dexie singleton lives in `db/internal.ts` and is INTERNAL to
      // the data layer. Only `db/**`, `hooks/**`, `firebase/**`, and tests may
      // import it (those dirs re-enable this rule to `off` below). Every other
      // module (components, pages) must go through an operations function
      // (`db/operations/*`) or a hook. `db/database.ts` no longer exports the
      // instance, so `db/internal` is the single import site to gate.
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['**/db/internal', '**/db/internal.*'],
              message:
                'The raw Dexie `db` instance is internal to the data layer. Import an operations function from `db/operations` or a hook instead (B3, issue #284).',
            },
          ],
        },
      ],
    },
  },

  // ─── DB layering boundary: allowed importers of `db/internal` ─────────────
  // These dirs ARE the data layer (operations / reactive hooks / sync) and
  // tests, so they may import the raw Dexie singleton directly.
  {
    files: [
      'src/db/**/*.{ts,tsx}',
      'src/hooks/**/*.{ts,tsx}',
      'src/firebase/**/*.{ts,tsx}',
      '**/__tests__/**/*.{ts,tsx}',
      '**/*.test.{ts,tsx}',
    ],
    rules: {
      'no-restricted-imports': 'off',
    },
  },

  // ─── Node config files ──────────────────────────────────────────────────────
  {
    files: ['vite.config.ts', 'eslint.config.js'],
    languageOptions: {
      globals: { ...globals.node },
    },
  },
];
