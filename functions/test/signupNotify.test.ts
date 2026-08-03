/**
 * Pure unit tests for the owner-notification message builder — no emulator
 * needed (the trigger wiring itself is exercised in production; the builder
 * carries the content contract).
 */
import { describe, it, expect } from "vitest";
import { buildSignupNotification } from "../src/signupNotify";

describe("buildSignupNotification", () => {
  it("puts the count and address in the subject", () => {
    const n = buildSignupNotification("fan@example.com", "coming-soon", 12);
    expect(n.subject).toBe("Signup #12 — fan@example.com");
  });

  it("text and html both carry count, email, and source", () => {
    const n = buildSignupNotification("fan@example.com", "coming-soon", 3);
    for (const body of [n.text, n.html]) {
      expect(body).toContain("#3");
      expect(body).toContain("fan@example.com");
      expect(body).toContain("coming-soon");
    }
  });
});
