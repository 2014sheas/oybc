/**
 * Signup-confirmation email template ("Variant A — Poster", chosen 2026-07-30).
 *
 * Bulletproof email HTML: tables + inline styles only, ZERO images — the mini
 * bingo board is colored table cells, so the email renders fully with images
 * disabled (Gmail default for unknown senders) and in every major client.
 * Known acceptable degradation: Outlook desktop drops border-radius (square
 * corners). Colors are the byte-values of the coming-soon page's Riso tokens
 * (apps/coming-soon/src/styles.css): paper #f1e9d9, paper-2 #fbf6ea, ink
 * #18120b, muted #7e7460, red #eb4d2e, blue #2c44c9, green #1f9b6b, gold
 * #ffc21f.
 *
 * The board mirrors the page's post-signup WON state: resting red/blue
 * pattern, center row completed in red with the gold ring, star center —
 * closing the loop on the animation the subscriber just watched.
 */

const INK = "#18120b";
const PAPER = "#f1e9d9";
const PAPER2 = "#fbf6ea";
const MUTED = "#7e7460";
const RED = "#eb4d2e";
const BLUE = "#2c44c9";
const GREEN = "#1f9b6b";
const GOLD = "#ffc21f";

/** One plain board cell (30×30 rounded square). */
function cell(color: string): string {
  return (
    `<td width="30" height="30" bgcolor="${color}" ` +
    `style="background-color:${color};border-radius:7px">&nbsp;</td>`
  );
}

/** One cell of the WON center row — gold ring; the middle carries the star. */
function wonCell(star = false): string {
  const bg = star ? INK : RED;
  const inner = star
    ? `color:${GOLD};font-size:16px;line-height:30px`
    : "";
  return (
    `<td width="30" height="30" bgcolor="${bg}" ${star ? 'align="center" ' : ""}` +
    `style="background-color:${bg};border-radius:7px;border:2px solid ${GOLD};${inner}">` +
    `${star ? "&#9733;" : "&nbsp;"}</td>`
  );
}

/** The 5×5 mini board on the ink plate, rows matching the page's won state. */
function miniBoard(): string {
  const P = PAPER2;
  const rows = [
    [RED, P, P, RED, P],
    [P, BLUE, RED, P, P],
    null, // won row
    [RED, P, BLUE, RED, P],
    [RED, BLUE, P, RED, P],
  ];
  const body = rows
    .map((row) =>
      row === null
        ? `<tr>${wonCell()}${wonCell()}${wonCell(true)}${wonCell()}${wonCell()}</tr>`
        : `<tr>${row.map(cell).join("")}</tr>`,
    )
    .join("");
  return (
    `<table role="presentation" cellpadding="0" cellspacing="3" bgcolor="${INK}" ` +
    `style="background-color:${INK};border-radius:14px;padding:6px">${body}</table>`
  );
}

const FONT = "font-family:Arial,Helvetica,sans-serif";

/**
 * Full HTML body for the confirmation email.
 *
 * @param season - Launch window copy (e.g. "Fall 2026").
 * @param unsubscribeUrl - Per-recipient unsubscribe link (footer + also sent
 *   as List-Unsubscribe headers by the caller).
 */
export function confirmationEmailHtml(season: string, unsubscribeUrl: string): string {
  return (
    `<!DOCTYPE html><html><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width"></head>` +
    `<body style="margin:0;padding:0;background-color:${PAPER}">` +
    // Hidden preheader (inbox preview line).
    `<div style="display:none;max-height:0;overflow:hidden;mso-hide:all">` +
    `Spot saved — we'll let you know when the doors open, ${season}.` +
    `&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div>` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="${PAPER}" style="background-color:${PAPER}">` +
    `<tr><td align="center" style="padding:32px 16px">` +
    `<table role="presentation" width="440" cellpadding="0" cellspacing="0" style="max-width:440px;width:100%">` +
    // Wordmark
    `<tr><td align="center" style="padding:0 0 18px;${FONT};font-weight:bold;font-size:15px;letter-spacing:2px;color:${INK}">` +
    `OYBC <span style="color:${MUTED};font-size:10px;letter-spacing:3px">&nbsp;ON YOUR BINGO CARD</span></td></tr>` +
    // Card
    `<tr><td>` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="${PAPER2}" ` +
    `style="background-color:${PAPER2};border:3px solid ${INK};border-radius:20px">` +
    // Stamp
    `<tr><td align="center" style="padding:28px 24px 8px">` +
    `<table role="presentation" cellpadding="0" cellspacing="0"><tr>` +
    `<td bgcolor="${GREEN}" style="background-color:${GREEN};border:2px solid ${INK};border-radius:999px;` +
    `padding:7px 16px;${FONT};font-weight:bold;font-size:12px;letter-spacing:2px;color:${PAPER2}">` +
    `&#9733;&nbsp;SPOT SAVED</td></tr></table></td></tr>` +
    // Headline + body
    `<tr><td align="center" style="padding:14px 24px 6px;${FONT};font-weight:bold;font-size:30px;line-height:1.1;color:${INK}">` +
    `You're on the board.</td></tr>` +
    `<tr><td align="center" style="padding:0 32px 22px;${FONT};font-size:15px;line-height:1.55;color:${INK}">` +
    `Thanks for grabbing a square. We'll let you know the moment OYBC opens — <b>${season}</b>. That's a bingo.</td></tr>` +
    // Board
    `<tr><td align="center" style="padding:0 24px 26px">${miniBoard()}</td></tr>` +
    // Product reminder
    `<tr><td align="center" style="padding:0 32px 26px;${FONT};font-size:13px;line-height:1.5;color:${MUTED}">` +
    `OYBC turns your goals into bingo boards — fill squares, line up rows, clear the board, repeat.</td></tr>` +
    `</table></td></tr>` +
    // Footer
    `<tr><td align="center" style="padding:20px 24px 0;${FONT};font-size:11.5px;line-height:1.6;color:${MUTED}">` +
    `You're getting this because you signed up at ` +
    `<a href="https://oybc.com" style="color:${RED};text-decoration:none;font-weight:bold">oybc.com</a>.<br>` +
    `No spam — just launch news.<br><br>` +
    `<a href="${unsubscribeUrl}" style="color:${MUTED};text-decoration:underline">Unsubscribe</a><br><br>` +
    `<span style="letter-spacing:1px">— OYBC · ON YOUR BINGO CARD</span></td></tr>` +
    `</table></td></tr></table></body></html>`
  );
}

/** Plain-text alternative, mirroring the HTML content. */
export function confirmationEmailText(season: string, unsubscribeUrl: string): string {
  return (
    `You're on the board.\n\n` +
    `Thanks for grabbing a square. We'll let you know the moment OYBC opens — ${season}. ` +
    `That's a bingo.\n\n` +
    `OYBC turns your goals into bingo boards — fill squares, line up rows, clear the board, repeat.\n\n` +
    `You're getting this because you signed up at oybc.com. No spam — just launch news.\n\n` +
    `Unsubscribe: ${unsubscribeUrl}\n\n` +
    `— OYBC · On Your Bingo Card`
  );
}
