/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_APP_TITLE: string
  // Add more env variables here as needed
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

// Build-time constant injected by vite.config.ts `define` — sourced from
// package.json#version so the footer is always in sync with the semver.
declare const __APP_VERSION__: string;

// Build identity (`<version>+<commit>`) injected by vite.config.ts `define`;
// read via `currentAppBuild()` (db/operations/syncQuarantine.ts), which falls
// back to 'dev' where the define is absent (vitest).
declare const __APP_BUILD__: string;
