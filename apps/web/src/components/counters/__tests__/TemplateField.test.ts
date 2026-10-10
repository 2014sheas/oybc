import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TemplateField } from '../TemplateField';
import { effectiveTemplate, renderTemplateExample } from '../templateFieldModel';
import { inputTag } from './inputTag';

const html = (p: Partial<React.ComponentProps<typeof TemplateField>>): string =>
  renderToStaticMarkup(
    React.createElement(TemplateField, {
      label: 'Singular title', id: 'tf', value: '', onChange: () => {}, derived: 'Read #N books', kind: 'discrete', exampleCount: 1, ...p,
    }),
  );

describe('TemplateField', () => {
  it('blank = unset: the derived default shows as the field text, dimmed, with its rendered value row', () => {
    const h = html({});
    const input = inputTag(h, 'id="tf"');
    expect(input).toContain('value="Read #N books"');
    expect(input).toContain('data-dim="true"');
    expect(input).toContain('maxLength="200"');
    expect(h).toContain('>Read 1 books<');
  });

  it('typed = solid: the typed template renders at the example count', () => {
    const h = html({ value: 'Read #N book', exampleCount: 1 });
    const input = inputTag(h, 'id="tf"');
    expect(input).toContain('value="Read #N book"');
    expect(input).not.toContain('data-dim');
    expect(h).toContain('>Read 1 book<');
    expect(html({ value: 'Read #N books', exampleCount: 12 })).toContain('>Read 12 books<');
  });

  it('kinds: Continuous 2.5, Duration 90 → 1h 30m; a template without #N renders as-is; empty → no row', () => {
    expect(html({ kind: 'continuous', value: 'Run #N miles', exampleCount: 2.5 })).toContain('>Run 2.5 miles<');
    expect(html({ kind: 'duration', value: 'Practice #N', exampleCount: 90 })).toContain('>Practice 1h 30m<');
    expect(html({ value: 'Finish the book', exampleCount: 12 })).toContain('>Finish the book<');
    expect(html({ derived: '', value: '' })).not.toContain('→');
  });

  it('pure helpers', () => {
    expect(effectiveTemplate('  ', 'Read #N books')).toBe('Read #N books');
    expect(effectiveTemplate(' Read #N book ', 'Read #N books')).toBe('Read #N book');
    expect(renderTemplateExample('', 1, 'discrete')).toBe('');
    expect(renderTemplateExample('#N pages, #N!', 12, 'discrete')).toBe('12 pages, 12!');
  });
});
