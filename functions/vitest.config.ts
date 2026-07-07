import { defineConfig } from "vitest/config";

/**
 * Both test files in this suite (`purge.test.ts`, `subscribe.test.ts`) share
 * ONE Firestore/Functions emulator instance (started once by
 * `firebase emulators:exec` around the whole `vitest run` invocation), and
 * both seed/read overlapping collection names. Run them sequentially — not
 * per-file-parallel workers — so a doc written by one file's setup can never
 * be read/raced against another file's assertions.
 *
 * `testTimeout` is generous because the very first test in the run pays for
 * emulator cold start (Firestore emulator JVM boot + first gRPC connection),
 * which can take several seconds beyond normal in-process test time.
 */
export default defineConfig({
  test: {
    globals: false,
    environment: "node",
    include: ["test/**/*.test.ts"],
    setupFiles: ["./test/setupEnv.ts"],
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
