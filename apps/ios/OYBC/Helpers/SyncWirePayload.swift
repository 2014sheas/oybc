import Foundation

/// Firestore wire shaping for pushed sync payloads (docs/SYNC_STRATEGY.md).
///
/// GRDB stores array/dictionary columns as JSON strings (e.g.
/// `completedLineIds: "[\"row_0\"]"`, `RecurringBoardTemplate.sources`).
/// Firestore must receive native arrays/dictionaries so web's Zod pull
/// validation (`RecurringBoardTemplateSchema` etc.) accepts the row.
/// `SyncService.writeFirestoreDoc` runs every pushed document through this.
enum SyncWirePayload {
    /// Keys whose string values are user text and must cross the wire verbatim.
    static let plainTextKeys: Set<String> = ["titleOverride", "title", "name", "description", "action", "unit", "counterName"]

    /// Drops `NSNull` values and expands JSON-encoded string values
    /// (a string starting with `[` or `{` that parses as JSON) back into
    /// native `[Any]` / `[String: Any]`. Every other value passes through
    /// unchanged — a non-JSON string that merely starts with `[` stays a string.
    static func expandJSONStrings(_ data: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (key, value) in data {
            if value is NSNull { continue }
            // Free-text fields are never expanded: a title like "[1]" is a
            // title, not a JSON array (review of #628 for `titleOverride`;
            // `title` / `name` / `description` carry the same hazard and are
            // listed here for the same reason).
            if plainTextKeys.contains(key) { cleaned[key] = value; continue }
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
