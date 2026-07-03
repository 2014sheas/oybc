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
