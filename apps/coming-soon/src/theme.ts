/* ============================================================
   OYBC · oybc.com — Day / Night theme toggle, shared by every
   page on the site (the Coming Soon poster and the legal pages).
   ============================================================ */

/**
 * Wires the `.cs-seg` Day / Night segmented control: a click toggles the
 * `.night` class on `<body>` (which swaps the Riso tokens in styles.css) and
 * keeps each button's `on` class + `aria-pressed` in step.
 *
 * Safe on a page without the control — it simply finds no buttons.
 */
export function initTheme(): void {
  const buttons = document.querySelectorAll<HTMLButtonElement>('.cs-seg button[data-theme]');
  buttons.forEach((btn) => {
    btn.addEventListener('click', () => {
      const night = btn.dataset.theme === 'night';
      document.body.classList.toggle('night', night);
      buttons.forEach((b) => {
        const on = b.dataset.theme === (night ? 'night' : 'day');
        b.classList.toggle('on', on);
        b.setAttribute('aria-pressed', String(on));
      });
    });
  });
}
