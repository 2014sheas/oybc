/**
 * Emulator-backed tests for the repo-root `firestore.rules`.
 *
 * These tests load the ACTUAL rules file (no copy, no inline duplicate) into
 * the Firestore emulator via `initializeTestEnvironment`, then exercise it
 * with the client SDK through per-user auth contexts. Run via
 * `npm test` (wraps `firebase emulators:exec` around `test:run`) so a real
 * emulator is always up before Firestore calls happen.
 *
 * Rule-line references below point at firestore.rules as of the commit that
 * introduced this suite; re-check them if the rules file changes shape.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteDoc, doc, getDoc, setDoc } from "firebase/firestore";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RULES_PATH = path.resolve(__dirname, "../../firestore.rules");
const PROJECT_ID = "demo-oybc-rules-test";

let testEnv: RulesTestEnvironment;

beforeAll(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(RULES_PATH, "utf8"),
      host: "127.0.0.1",
      port: 8080,
    },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

/** A valid payload for a top-level entity collection (firestore.rules:33-42
 * lists `boards` under `requiresUserIdField()`), satisfying hasAll(['id',
 * 'version']) + version-is-number + id===docId + userId===path uid. */
function boardPayload(
  userId: string,
  id: string,
  overrides: Record<string, unknown> = {},
) {
  return {
    id,
    version: 1,
    userId,
    name: "Test board",
    ...overrides,
  };
}

/** A valid payload for a child-entity collection that does NOT require a
 * `userId` field (firestore.rules:37-42 — `boardTasks` is in the known-
 * collection whitelist but absent from `requiresUserIdField()`). */
function childPayload(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    version: 1,
    ...overrides,
  };
}

describe("users/{userId} parent doc (firestore.rules:6-19)", () => {
  it("allows the owner to create/read their own user doc", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}`);
    await assertSucceeds(setDoc(ref, { id: uid, version: 1 }));
    await assertSucceeds(getDoc(ref));
  });

  it("denies an unauthenticated caller from reading a user doc", async () => {
    const anonDb = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(anonDb, "users/alice")));
  });

  it("denies a different authenticated user from reading another user's doc", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "users/alice"), {
        id: "alice",
        version: 1,
      });
    });
    const mallory = testEnv.authenticatedContext("mallory").firestore();
    await assertFails(getDoc(doc(mallory, "users/alice")));
  });

  it("denies a different authenticated user from writing another user's doc", async () => {
    const mallory = testEnv.authenticatedContext("mallory").firestore();
    await assertFails(
      setDoc(doc(mallory, "users/alice"), { id: "alice", version: 1 }),
    );
  });

  it("denies writing a user doc whose payload id does not match the path uid (line 14)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    await assertFails(setDoc(doc(db, `users/${uid}`), { id: "bob", version: 1 }));
  });

  it("denies deleting the parent user document (line 18: allow delete: if false)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}`);
    await assertSucceeds(setDoc(ref, { id: uid, version: 1 }));
    await assertFails(deleteDoc(ref));
  });
});

describe("users/{userId}/{collection}/{docId} subcollections (firestore.rules:21-74)", () => {
  it("allows the owner to write, read, and delete a known-collection doc with a valid payload", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertSucceeds(setDoc(ref, boardPayload(uid, "board1")));
    await assertSucceeds(getDoc(ref));
    await assertSucceeds(deleteDoc(ref));
  });

  it("allows a child-entity collection without a userId field, per requiresUserIdField() (lines 37-42)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boardTasks/bt1`);
    await assertSucceeds(setDoc(ref, childPayload("bt1")));
  });

  it("denies a different authenticated user from reading another user's subcollection doc", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), "users/alice/boards/board1"),
        boardPayload("alice", "board1"),
      );
    });
    const mallory = testEnv.authenticatedContext("mallory").firestore();
    await assertFails(getDoc(doc(mallory, "users/alice/boards/board1")));
  });

  it("denies a different authenticated user from writing to another user's path", async () => {
    const mallory = testEnv.authenticatedContext("mallory").firestore();
    await assertFails(
      setDoc(
        doc(mallory, "users/alice/boards/board1"),
        boardPayload("alice", "board1"),
      ),
    );
  });

  it("denies a different authenticated user from deleting another user's subcollection doc", async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), "users/alice/boards/board1"),
        boardPayload("alice", "board1"),
      );
    });
    const mallory = testEnv.authenticatedContext("mallory").firestore();
    await assertFails(deleteDoc(doc(mallory, "users/alice/boards/board1")));
  });

  it("denies a top-level entity write whose payload userId spoofs a different uid (userIdMatchesPath, lines 49-52)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertFails(setDoc(ref, boardPayload("mallory", "board1")));
  });

  it("denies read and write on an unknown subcollection name (isKnownCollection whitelist, lines 23-31)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/notARealCollection/doc1`);
    await assertFails(setDoc(ref, childPayload("doc1")));
    await assertFails(getDoc(ref));
  });

  it("denies a write missing the id and version fields (hasAll, line 64)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertFails(setDoc(ref, { userId: uid, name: "no id or version" }));
  });

  it("denies a write whose version field is not a number (line 65)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertFails(
      setDoc(ref, boardPayload(uid, "board1", { version: "1" })),
    );
  });

  it("denies a write whose payload id does not match the document id (line 66)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertFails(setDoc(ref, boardPayload(uid, "not-board1")));
  });

  it("denies a write at or above the 10000-byte size cap (line 68)", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    const ref = doc(db, `users/${uid}/boards/board1`);
    await assertFails(
      setDoc(
        ref,
        boardPayload(uid, "board1", { blob: "x".repeat(10500) }),
      ),
    );
  });
});

describe("signups collection — fully client-denied (falls through to the catch-all, lines 76-79)", () => {
  it("denies an authenticated user from reading or writing signups", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    await assertFails(
      setDoc(doc(db, "signups/somehash"), { email: "a@b.com" }),
    );
    await assertFails(getDoc(doc(db, "signups/somehash")));
  });

  it("denies an unauthenticated caller from reading or writing signups", async () => {
    const anonDb = testEnv.unauthenticatedContext().firestore();
    await assertFails(
      setDoc(doc(anonDb, "signups/somehash"), { email: "a@b.com" }),
    );
    await assertFails(getDoc(doc(anonDb, "signups/somehash")));
  });
});

describe("default-deny terminal match (firestore.rules:77-79)", () => {
  it("denies read and write on an arbitrary top-level collection outside users/{userId}", async () => {
    const uid = "alice";
    const db = testEnv.authenticatedContext(uid).firestore();
    await assertFails(getDoc(doc(db, "randomTopLevelThing/doc1")));
    await assertFails(
      setDoc(doc(db, "randomTopLevelThing/doc1"), { id: "doc1", version: 1 }),
    );
  });
});
