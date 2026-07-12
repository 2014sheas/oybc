/**
 * Deterministic RFC 4122 v5 (SHA-1, name-based) UUID generation — pure TS,
 * no dependencies, so the iOS twin can mirror it byte-for-byte with
 * CryptoKit's `Insecure.SHA1` + the same namespace bytes.
 *
 * Used by the Windowed Completion backfill (docs/WINDOWED_COMPLETION.md
 * §Migration & backfill) to mint deterministic, kind-qualified event ids:
 * two devices deriving events from the same task snapshot produce the SAME
 * id, which is what makes the union-dedupe converge.
 *
 * Only the two entry points here are public: `uuidv5(name, namespace)` and
 * the project `OYBC_NAMESPACE` constant.
 */

/**
 * OYBC project UUID namespace (v5 name-based hashing). Fixed constant — the
 * bytes of this UUID are prepended to the name before hashing. Changing it
 * would change every deterministic id, so it must never change once shipped.
 * The iOS twin hard-codes the identical 16 bytes.
 */
export const OYBC_NAMESPACE = '2b3c4d5e-6f70-4a8b-9c0d-1e2f3a4b5c6d';

/** Parse a canonical UUID string into its 16 raw bytes. */
function uuidToBytes(uuid: string): number[] {
  const hex = uuid.replace(/-/g, '');
  if (hex.length !== 32) {
    throw new Error(`Invalid UUID (expected 32 hex chars): ${uuid}`);
  }
  const bytes: number[] = [];
  for (let i = 0; i < 16; i += 1) {
    bytes.push(parseInt(hex.slice(i * 2, i * 2 + 2), 16));
  }
  return bytes;
}

/** Encode a JS string as UTF-8 bytes (matches Swift `Array(name.utf8)`). */
function utf8Bytes(str: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < str.length; i += 1) {
    let code = str.charCodeAt(i);
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code <= 0xdbff) {
      // High surrogate — combine with the following low surrogate.
      const hi = code;
      const lo = str.charCodeAt(i + 1);
      i += 1;
      code = 0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00);
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return out;
}

function rotl(x: number, n: number): number {
  return ((x << n) | (x >>> (32 - n))) >>> 0;
}

/**
 * SHA-1 over a byte array → 20-byte digest. Standard FIPS 180-1
 * implementation kept intentionally literal so the Swift side can be a
 * plain `Insecure.SHA1.hash` (identical output) rather than a re-port.
 */
function sha1(bytes: number[]): number[] {
  const ml = bytes.length * 8;
  const msg = bytes.slice();
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  // 64-bit big-endian message length. Bit length fits in 32 bits for our
  // inputs, so the high word is always 0.
  for (let i = 0; i < 4; i += 1) msg.push(0);
  msg.push((ml >>> 24) & 0xff, (ml >>> 16) & 0xff, (ml >>> 8) & 0xff, ml & 0xff);

  let h0 = 0x67452301;
  let h1 = 0xefcdab89;
  let h2 = 0x98badcfe;
  let h3 = 0x10325476;
  let h4 = 0xc3d2e1f0;

  const w = new Array<number>(80);
  for (let chunk = 0; chunk < msg.length; chunk += 64) {
    for (let i = 0; i < 16; i += 1) {
      w[i] =
        ((msg[chunk + i * 4] << 24) |
          (msg[chunk + i * 4 + 1] << 16) |
          (msg[chunk + i * 4 + 2] << 8) |
          msg[chunk + i * 4 + 3]) >>>
        0;
    }
    for (let i = 16; i < 80; i += 1) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;

    for (let i = 0; i < 80; i += 1) {
      let f: number;
      let k: number;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      const temp = (rotl(a, 5) + f + e + k + w[i]) >>> 0;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
  }

  const out: number[] = [];
  for (const h of [h0, h1, h2, h3, h4]) {
    out.push((h >>> 24) & 0xff, (h >>> 16) & 0xff, (h >>> 8) & 0xff, h & 0xff);
  }
  return out;
}

function byteToHex(b: number): string {
  return b.toString(16).padStart(2, '0');
}

/**
 * Compute the RFC 4122 v5 UUID for `name` under `namespace`.
 *
 * @param name       The name to hash (UTF-8 encoded).
 * @param namespace  Canonical namespace UUID string. Defaults to
 *                   {@link OYBC_NAMESPACE}.
 * @returns A canonical lowercase UUID string with version 5 + RFC variant bits.
 */
export function uuidv5(name: string, namespace: string = OYBC_NAMESPACE): string {
  const nsBytes = uuidToBytes(namespace);
  const nameBytes = utf8Bytes(name);
  const hash = sha1(nsBytes.concat(nameBytes));
  const b = hash.slice(0, 16);
  // Version 5.
  b[6] = (b[6] & 0x0f) | 0x50;
  // RFC 4122 variant.
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = b.map(byteToHex).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
