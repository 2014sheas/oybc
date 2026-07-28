import { uuidv5, OYBC_NAMESPACE } from '../../src/algorithms/uuidv5';

/**
 * uuidv5.test.ts — the deterministic RFC 4122 v5 generator backing the
 * Windowed Completion backfill ids. The RFC known-answer vector guards the
 * SHA-1 implementation; determinism + version/variant bits guard the id shape
 * the iOS twin must reproduce.
 */

const DNS_NAMESPACE = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

describe('uuidv5', () => {
  it('matches the RFC 4122 known-answer vector (www.example.com under DNS namespace)', () => {
    expect(uuidv5('www.example.com', DNS_NAMESPACE)).toBe('2ed6657d-e927-568b-95e1-2665a8aea6a2');
  });

  it('is deterministic (same name + namespace → same id)', () => {
    expect(uuidv5('abc', OYBC_NAMESPACE)).toBe(uuidv5('abc', OYBC_NAMESPACE));
  });

  it('different names produce different ids', () => {
    expect(uuidv5('abc', OYBC_NAMESPACE)).not.toBe(uuidv5('abd', OYBC_NAMESPACE));
  });

  it('different namespaces produce different ids for the same name', () => {
    expect(uuidv5('abc', OYBC_NAMESPACE)).not.toBe(uuidv5('abc', DNS_NAMESPACE));
  });

  it('defaults to OYBC_NAMESPACE when namespace omitted', () => {
    expect(uuidv5('abc')).toBe(uuidv5('abc', OYBC_NAMESPACE));
  });

  it('sets the version-5 nibble and RFC variant bits', () => {
    const id = uuidv5('anything', OYBC_NAMESPACE);
    expect(id).toMatch(UUID_RE);
    // version nibble (first char of 3rd group) == '5'
    expect(id.split('-')[2][0]).toBe('5');
    // variant high bits of 4th group ∈ {8,9,a,b}
    expect('89ab').toContain(id.split('-')[3][0]);
  });

  it('handles multi-byte UTF-8 names deterministically', () => {
    expect(uuidv5('café–π', OYBC_NAMESPACE)).toBe(uuidv5('café–π', OYBC_NAMESPACE));
    expect(uuidv5('café–π', OYBC_NAMESPACE)).toMatch(UUID_RE);
  });

  it('handles astral-plane (surrogate-pair) names', () => {
    expect(uuidv5('😀', OYBC_NAMESPACE)).toMatch(UUID_RE);
    expect(uuidv5('😀', OYBC_NAMESPACE)).toBe(uuidv5('😀', OYBC_NAMESPACE));
  });

  it('throws on a malformed namespace UUID', () => {
    expect(() => uuidv5('x', 'not-a-uuid')).toThrow();
  });
});
