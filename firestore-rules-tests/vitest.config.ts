import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
    // The emulator round-trips are local loopback calls, but CI runners can
    // be slow to schedule the JVM-backed emulator's first response — give
    // hooks/tests more headroom than vitest's 5s default to avoid flakes.
    testTimeout: 20000,
    hookTimeout: 20000,
  },
});
