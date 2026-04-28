import Foundation
import GRDB

/// CompoundChild — one parent-child link in a compound task's structure.
///
/// Matches TypeScript CompoundChild interface from @oybc/shared.
/// Replaces task_steps (for progress) and composite_nodes leaves (for composite)
/// under the unified compound model. The parent compound's operator + threshold
/// + isOrdered fields live on the Task row itself.
///
/// The child can be ANY Task — primitive (normal/counting) or another compound.
/// Nesting is natural: a compound's children may themselves resolve to compound
/// rows whose own children are evaluated recursively.
struct CompoundChild: Codable, FetchableRecord, PersistableRecord, Identifiable {
    // Identity
    var id: String
    var compoundTaskId: String   // FK to tasks (parent compound)
    var childTaskId: String      // FK to tasks (child — any type, including nested compound)

    // Ordering
    var childIndex: Int          // 0-based; honored when parent.isOrdered

    // Timestamps
    var createdAt: String        // ISO8601
    var updatedAt: String        // ISO8601

    // Sync metadata
    var lastSyncedAt: String?    // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?       // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "compound_children"

    /// The parent compound Task (via `compoundTaskId`).
    static let parentCompound = belongsTo(Task.self, using: ForeignKey(["compoundTaskId"]))

    /// The child Task (via `childTaskId`). Explicit ForeignKey since CompoundChild
    /// has two FK columns to `tasks` (parent + child) — GRDB needs the disambiguator.
    static let childTask = belongsTo(Task.self, using: ForeignKey(["childTaskId"]))
}
