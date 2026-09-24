/**
 * Unit tests (mocked Admin SDK — no emulator round-trips) for the ORDER of
 * writes in the account purge: the `deletedUsers/{uid}` marker must be written
 * BEFORE the recursive delete, on BOTH entry points (`onUserDeleted` Auth
 * trigger + `deleteUserData` callable). `firestore.rules` refuses client
 * writes under `users/{uid}` once the marker exists; writing it first closes
 * the window where a deleted user's still-valid ID token re-creates docs
 * mid-purge. The real delete semantics are covered against the emulator in
 * `purge.test.ts`.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { deleteUserData, onUserDeleted } from "../src/index";
import { purgeUserData } from "../src/purgeUser";

// `vi.mock` factories are hoisted above the imports, so the state they close
// over must be hoisted too.
const h = vi.hoisted(() => ({
  SERVER_TS: { __sentinel: "serverTimestamp" },
  /** Ordered log of every Firestore mutation the code under test performs. */
  calls: [] as string[],
  failMarkerWrite: false,
}));
const { SERVER_TS, calls } = h;

vi.mock("firebase-admin/app", () => ({ initializeApp: vi.fn() }));

vi.mock("firebase-admin/firestore", () => {
  const ref = (path: string) => ({
    path,
    set: vi.fn(async (data: unknown) => {
      calls.push(`set:${path}:${JSON.stringify(data)}`);
      if (h.failMarkerWrite && path.startsWith("deletedUsers/")) {
        throw new Error("marker write failed");
      }
    }),
  });
  const db = {
    collection: (name: string) => ({ doc: (id: string) => ref(`${name}/${id}`) }),
    recursiveDelete: vi.fn(async (r: { path: string }) => {
      calls.push(`recursiveDelete:${r.path}`);
    }),
  };
  return {
    getFirestore: () => db,
    FieldValue: { serverTimestamp: () => h.SERVER_TS, delete: () => ({}) },
  };
});


const MARKER = (uid: string) =>
  `set:deletedUsers/${uid}:${JSON.stringify({ deletedAt: SERVER_TS })}`;

beforeEach(() => {
  calls.length = 0;
  h.failMarkerWrite = false;
});

describe("purgeUserData write order", () => {
  it("writes the deletedUsers marker, then recursively deletes users/{uid}", async () => {
    await purgeUserData("u1");
    expect(calls).toEqual([MARKER("u1"), "recursiveDelete:users/u1"]);
  });

  it("deletes nothing when the marker write fails (error propagates for retry)", async () => {
    h.failMarkerWrite = true;
    await expect(purgeUserData("u1")).rejects.toThrow("marker write failed");
    expect(calls).toEqual([MARKER("u1")]);
  });
});

describe("entry points route through the marker-first purge", () => {
  it("onUserDeleted (primary Auth-trigger path) writes the marker before the first delete", async () => {
    await (onUserDeleted as unknown as {
      run: (user: unknown, ctx: unknown) => Promise<void>;
    }).run({ uid: "trig-1" }, {});
    expect(calls).toEqual([MARKER("trig-1"), "recursiveDelete:users/trig-1"]);
  });

  it("deleteUserData (callable) writes the marker before the first delete, for the verified caller uid", async () => {
    const result = await (deleteUserData as unknown as {
      run: (req: unknown) => Promise<unknown>;
    }).run({ auth: { uid: "call-1" }, data: { uid: "someone-else" } });
    expect(result).toEqual({ ok: true });
    expect(calls).toEqual([MARKER("call-1"), "recursiveDelete:users/call-1"]);
  });

  it("deleteUserData rejects an unauthenticated caller without writing anything", async () => {
    await expect(
      (deleteUserData as unknown as { run: (req: unknown) => Promise<unknown> }).run({
        data: {},
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
    expect(calls).toEqual([]);
  });
});
