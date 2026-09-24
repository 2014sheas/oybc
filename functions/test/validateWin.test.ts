/**
 * Unit tests for the `validateWin` callable (functions/src/validateWin.ts),
 * invoked in-process through the v2 `onCall` wrapper's `.run(request)` — no
 * HTTP or emulator round-trip needed (the handler touches no Firestore).
 */
import { describe, it, expect } from "vitest";
import { HttpsError } from "firebase-functions/v2/https";
import { validateWin } from "../src/validateWin";

type RunArg = Parameters<typeof validateWin.run>[0];

/** `auth: null` models an unauthenticated caller. */
function call(data: unknown, auth: { uid: string } | null = { uid: "alice" }) {
  return validateWin.run({
    data,
    auth: auth ? { uid: auth.uid, token: {} } : undefined,
    rawRequest: {},
    acceptsStreaming: false,
  } as unknown as RunArg);
}

async function codeOf(p: () => unknown): Promise<string | undefined> {
  try {
    await p();
  } catch (err) {
    return err instanceof HttpsError ? err.code : "non-https-error";
  }
  return undefined;
}

describe("validateWin", () => {
  it("rejects an unauthenticated caller with 'unauthenticated'", async () => {
    const grid = Array(9).fill(true);
    expect(await codeOf(() => call({ completionGrid: grid, gridSize: 3 }, null))).toBe(
      "unauthenticated",
    );
  });

  it("rejects a grid shorter than gridSize² with 'invalid-argument'", async () => {
    expect(await codeOf(() => call({ completionGrid: Array(8).fill(true), gridSize: 3 }))).toBe(
      "invalid-argument",
    );
  });

  it("rejects a grid longer than gridSize² with 'invalid-argument'", async () => {
    // 25 all-true cells with gridSize 3 would otherwise "win" on the first 9.
    expect(await codeOf(() => call({ completionGrid: Array(25).fill(true), gridSize: 3 }))).toBe(
      "invalid-argument",
    );
  });

  it("accepts an authenticated, well-formed 3x3 full grid as a win", async () => {
    const result = (await call({ completionGrid: Array(9).fill(true), gridSize: 3 })) as {
      isWin: boolean;
      completedLines: unknown[];
    };
    expect(result.isWin).toBe(true);
    expect(result.completedLines.length).toBeGreaterThan(0);
  });

  it("accepts an authenticated, well-formed empty 4x4 grid as a non-win", async () => {
    const result = (await call({ completionGrid: Array(16).fill(false), gridSize: 4 })) as {
      isWin: boolean;
    };
    expect(result.isWin).toBe(false);
  });
});
