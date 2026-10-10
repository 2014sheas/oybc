import type { CountKind } from '@oybc/shared';
import { TEMPLATE_MAX_LENGTH, effectiveTemplate, renderTemplateExample } from './templateFieldModel';
import styles from './TemplateField.module.css';

export interface TemplateFieldProps {
  /** "Singular title" / "Plural title". */
  label: string;
  id: string;
  /** The typed template (`''` = unset — the derived default shows dimmed). */
  value: string;
  onChange: (next: string) => void;
  /** The generator default for the sheet's live verb / noun / kind. */
  derived: string;
  kind: CountKind;
  /** The count the value row renders `#N` with (singular 1; plural 12 / 2.5 / 90). */
  exampleCount: number;
}

/**
 * TemplateField — the `#N` title field (docs/SHARED_COUNTER_SETTINGS.md §1b;
 * design handoff `TemplateField.dc.html`). A plain native text input holding
 * the template as text (the default value already contains `#N` — that is the
 * teaching), with the live-rendered value under it as a value row
 * (`→ Read 1 book`). Blank = unset: the derived default shows DIMMED (muted
 * text, hairline keyline) as real text the user types over; typing makes it
 * solid and stores it; clearing returns it to the dimmed default. Caps the
 * entry at {@link TEMPLATE_MAX_LENGTH}. iOS twin: `TemplateFieldView`.
 *
 * @returns The labelled field + value row.
 */
export function TemplateField({ label, id, value, onChange, derived, kind, exampleCount }: TemplateFieldProps): React.ReactElement {
  const dim = value.trim() === '';
  const rendered = renderTemplateExample(effectiveTemplate(value, derived), exampleCount, kind);
  return (
    <div className={styles.wrap}>
      <label className={styles.label} htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        type="text"
        spellCheck={false}
        maxLength={TEMPLATE_MAX_LENGTH}
        value={dim ? derived : value}
        onChange={(e) => onChange(e.target.value)}
        className={`${styles.input} ${dim ? styles.dim : ''}`}
        data-dim={dim || undefined}
      />
      {rendered !== '' && (
        <div className={styles.example} aria-label={`${label} renders as`}>
          <span className={styles.arrow} aria-hidden="true">
            →
          </span>
          <span className={`${styles.rendered} ${dim ? styles.renderedDim : ''}`}>{rendered}</span>
        </div>
      )}
    </div>
  );
}
