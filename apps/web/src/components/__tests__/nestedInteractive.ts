/**
 * Test helper: finds interactive elements nested inside other interactive
 * elements in a static HTML string (e.g. `renderToStaticMarkup` output).
 *
 * "Interactive" = a `<button>`, `<a href>`, `<input>`, `<select>`,
 * `<textarea>`, or any element carrying `role="button"`. A control nested in
 * another is the ARIA nested-interactive violation — and, when the outer one
 * is a `role="button"` with an Enter/Space `preventDefault()` handler, the
 * inner control is dead to the keyboard (2026-09 audit).
 *
 * A deliberately tiny tag-stack scanner, not a full HTML parser: it is only
 * ever fed React's serializer output, which always closes non-void tags.
 *
 * @param html - Static markup to scan.
 * @returns One `"<outer> > <inner>"` description per violation (empty when
 *   the markup is clean).
 */
export function findNestedInteractives(html: string): string[] {
  const VOID = new Set([
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
    'source', 'track', 'wbr',
  ]);
  const stack: { tag: string; interactive: boolean; label: string }[] = [];
  const violations: string[] = [];
  const TAG = /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)([^>]*?)(\/?)>/g;
  let m: RegExpExecArray | null;
  while ((m = TAG.exec(html)) !== null) {
    const [, closing, rawTag, attrs, selfClosing] = m;
    const tag = rawTag.toLowerCase();
    if (closing) {
      // Pop back to the matching open tag.
      for (let i = stack.length - 1; i >= 0; i--) {
        if (stack[i].tag === tag) {
          stack.length = i;
          break;
        }
      }
      continue;
    }
    const interactive =
      tag === 'button' ||
      tag === 'input' ||
      tag === 'select' ||
      tag === 'textarea' ||
      (tag === 'a' && /\shref=/.test(attrs)) ||
      /\srole="button"/.test(attrs);
    const ariaLabel = /\saria-label="([^"]*)"/.exec(attrs)?.[1];
    const label = ariaLabel ? `<${tag} "${ariaLabel}">` : `<${tag}>`;
    if (interactive) {
      const outer = [...stack].reverse().find((e) => e.interactive);
      if (outer) violations.push(`${outer.label} > ${label}`);
    }
    if (!VOID.has(tag) && !selfClosing) stack.push({ tag, interactive, label });
  }
  return violations;
}
