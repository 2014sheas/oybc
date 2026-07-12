import Foundation
import CryptoKit

// MARK: - UUIDv5 (Swift port of uuidv5.ts)
//
// Swift port of `packages/shared/src/algorithms/uuidv5.ts`. Deterministic
// RFC 4122 v5 (SHA-1, name-based) UUID generation. The TS file is the source
// of truth; any change to the namespace or algorithm there MUST be mirrored
// here — the two implementations must produce byte-identical output.
//
// Used by the Windowed Completion backfill (docs/WINDOWED_COMPLETION.md
// §Migration & backfill) to mint deterministic, kind-qualified event ids: two
// devices deriving events from the same task snapshot produce the SAME id,
// which is what makes the union-dedupe converge.
//
// Unlike the TS twin — which hand-rolls SHA-1 so it has no dependency — this
// port uses CryptoKit's `Insecure.SHA1`, hard-coding the IDENTICAL namespace
// bytes. The known-answer RFC 4122 vector (DNS namespace / `www.example.com` →
// `2ed6657d-e927-568b-95e1-2665a8aea6a2`) plus the OYBC backfill-id fixtures in
// `OYBCTests/Fixtures/backfillEventVectors.json` pin cross-platform agreement.

enum UUIDv5 {
    /// OYBC project UUID namespace (v5 name-based hashing). Fixed constant —
    /// its 16 bytes are prepended to the name before hashing. Must be BYTE-
    /// IDENTICAL to `OYBC_NAMESPACE` in `uuidv5.ts`. Changing it would change
    /// every deterministic id, so it must never change once shipped.
    static let oybcNamespace = "2b3c4d5e-6f70-4a8b-9c0d-1e2f3a4b5c6d"

    /// Parse a canonical UUID string into its 16 raw bytes.
    private static func uuidToBytes(_ uuid: String) -> [UInt8] {
        let hex = uuid.replacingOccurrences(of: "-", with: "")
        precondition(hex.count == 32, "Invalid UUID (expected 32 hex chars): \(uuid)")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            // Force-unwrap is safe: a canonical UUID is all hex digits.
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// Compute the RFC 4122 v5 UUID for `name` under `namespace`.
    ///
    /// Mirrors `uuidv5(name, namespace)` in the TS twin: SHA-1 over
    /// `namespaceBytes ++ utf8(name)`, take the first 16 bytes, stamp the
    /// version (5) and RFC-4122 variant bits, and format as a canonical
    /// lowercase UUID string.
    ///
    /// - Parameters:
    ///   - name: The name to hash (UTF-8 encoded — matches JS `utf8Bytes`).
    ///   - namespace: Canonical namespace UUID string. Defaults to
    ///     ``oybcNamespace``.
    /// - Returns: A canonical lowercase UUID string with version 5 + RFC variant.
    static func uuidv5(name: String, namespace: String = oybcNamespace) -> String {
        let nsBytes = uuidToBytes(namespace)
        let nameBytes = Array(name.utf8)
        let digest = Insecure.SHA1.hash(data: Data(nsBytes + nameBytes))
        var b = Array(digest.prefix(16)) // SHA-1 digest is 20 bytes; take first 16.
        // Version 5.
        b[6] = (b[6] & 0x0f) | 0x50
        // RFC 4122 variant.
        b[8] = (b[8] & 0x3f) | 0x80
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        func slice(_ lo: Int, _ hi: Int) -> String { String(s[lo..<hi]) }
        return "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
    }
}
