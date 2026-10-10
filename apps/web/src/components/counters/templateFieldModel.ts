import { renderCounterTitle, type CountKind } from '@oybc/shared';

/** Zod's cap on a stored title template. */
export const TEMPLATE_MAX_LENGTH = 200;

/**
 * The template a `TemplateField` is effectively showing: the typed one, else
 * the derived default.
 *
 * @param value - The typed template.
 * @param derived - The derived default.
 */
export function effectiveTemplate(value: string, derived: string): string {
  return value.trim() === '' ? derived : value.trim();
}

/**
 * The value row's text for a template (`#N` → the count at `kind`; a template
 * without `#N` renders as-is; `''` for an empty template).
 *
 * @param template - The effective template.
 * @param count - The example count.
 * @param kind - The counter's kind.
 */
export function renderTemplateExample(template: string, count: number, kind: CountKind): string {
  if (template.trim() === '') return '';
  return renderCounterTitle({ titleTemplatePlural: template, countKind: kind }, count);
}
