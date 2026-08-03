/**
 * Launch-push delight: email the owner when someone genuinely NEW joins the
 * signups list (Firestore onDocumentCreated — re-signups and unsubscribes are
 * merges/updates on existing docs and never fire this).
 *
 * Pure message-builder split out so it's unit-testable without the emulator
 * (`functions/test/signupNotify.test.ts`).
 */

/** Subject + bodies for the owner-notification email. */
export interface SignupNotification {
  subject: string;
  text: string;
  html: string;
}

/**
 * Build the owner notification for one new signup.
 *
 * @param email - The new subscriber's address (owner's own data — fine to include).
 * @param source - The signup's `source` field (e.g. "coming-soon").
 * @param count - Total non-unsubscribed signups AFTER this one (aggregate count).
 */
export function buildSignupNotification(
  email: string,
  source: string,
  count: number,
): SignupNotification {
  const subject = `Signup #${count} — ${email}`;
  const text =
    `New square claimed.\n\n` +
    `#${count} · ${email}\n` +
    `source: ${source}\n\n` +
    `— oybc.com launch list`;
  const html =
    `<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;` +
    `max-width:420px;margin:0 auto;padding:20px;color:#18120b">` +
    `<p style="font-size:13px;letter-spacing:2px;font-weight:800;color:#1f9b6b;margin:0 0 8px">&#9733; NEW SQUARE CLAIMED</p>` +
    `<p style="font-size:20px;font-weight:800;margin:0 0 4px">#${count} &middot; ${email}</p>` +
    `<p style="font-size:12.5px;color:#7e7460;margin:0">source: ${source} &middot; oybc.com launch list</p>` +
    `</div>`;
  return { subject, text, html };
}
