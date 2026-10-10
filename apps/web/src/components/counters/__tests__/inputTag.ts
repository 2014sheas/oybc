/**
 * The `<input …>` tag in `html` that carries `attr` (e.g. `aria-label="Weekly default"`),
 * or `''` — so a test can assert on another attribute of the same tag without
 * depending on React's attribute order.
 *
 * @param html - Rendered static markup.
 * @param attr - An attribute text unique to one input.
 */
export function inputTag(html: string, attr: string): string {
  const tags = html.match(/<input[^>]*>/g) ?? [];
  return tags.find((t) => t.includes(attr)) ?? '';
}
