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

  it("escapes HTML in attacker-controllable fields (html part only)", () => {
    const n = buildSignupNotification(
      "<img src=x onerror=alert(1)>@a.co",
      "<script>evil()</script>",
      1,
    );
    expect(n.html).not.toContain("<img");
    expect(n.html).not.toContain("<script>");
    expect(n.html).toContain("&lt;img src=x onerror=alert(1)&gt;@a.co");
    expect(n.html).toContain("&lt;script&gt;evil()&lt;/script&gt;");
    // Plain text is not rendered as HTML — stays verbatim.
    expect(n.text).toContain("<script>evil()</script>");
  });
});
