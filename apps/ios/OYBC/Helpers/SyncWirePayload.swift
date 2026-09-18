import Foundation

/// Firestore wire shaping for pushed sync payloads (docs/SYNC_STRATEGY.md).
///
/// GRDB stores array/dictionary columns as JSON strings (e.g.
/// `completedLineIds: "[\"row_0\"]"`, `RecurringBoardTemplate.sources`).
/// Firestore must receive native arrays/dictionaries so web's Zod pull
/// validation (`RecurringBoardTemplateSchema` etc.) accepts the row.
/// `SyncService.writeFirestoreDoc` runs every pushed document through this.
enum SyncWirePayload {
    /// Drops `NSNull` values and expands JSON-encoded string values
    /// (a string starting with `[` or `{` that parses as JSON) back into
    /// native `[Any]` / `[String: Any]`. Every other value passes through
    /// unchanged — a non-JSON string that merely starts with `[` stays a string.
    static func expandJSONStrings(_ data: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (key, value) in data {
            if value is NSNull { continue }
            if let str = value as? String, str.hasPrefix("[") || str.hasPrefix("{") {
                if let jsonData = str.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                    cleaned[key] = parsed
                    continue
                }
            }
            cleaned[key] = value
        }
        return cleaned
    }
}
