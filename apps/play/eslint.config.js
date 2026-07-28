// ESLint 10 flat config. Same base as apps/web's, plus the boundary rule
// that keeps Play from importing Do's domain layer (@oybc/shared).

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
    },
  },

  // ─── Package boundary: Play never imports Do's domain layer ────────────────
  {
    rules: {
      'no-restricted-imports': ['error', {
        paths: [{
          name: '@oybc/shared',
          message: "Play must not import Do's domain layer. Game math lives in @oybc/bingo-core; if you need something from shared, it either moves to bingo-core (if it's pure game math) or gets reimplemented against Play's own session model.",
        }],
        patterns: [{ group: ['@oybc/shared/*'], message: 'See @oybc/shared restriction.' }],
      }],
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
