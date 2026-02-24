import Foundation
import GRDB

/// CompositeTask - Root composite task definition
///
/// A composite task composes existing tasks using logical operators
/// (AND, OR, M_OF_N). It is NOT a TaskType — it lives in its own
/// composite_tasks table alongside the tasks table.
///
/// Matches TypeScript CompositeTask interface from @oybc/shared
struct CompositeTask: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var userId: String

    // Core fields
    var title: String
    var description: String?

    // Tree structure
    var rootNodeId: String           // FK to composite_nodes (root of tree)

    // Timestamps
    var createdAt: String            // ISO8601
    var updatedAt: String            // ISO8601

    // Sync metadata
    var lastSyncedAt: String?        // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?           // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "composite_tasks"
    static let rootNode = belongsTo(CompositeNode.self,
                                    using: ForeignKey(["rootNodeId"]))
    static let nodes = hasMany(CompositeNode.self)
}

// MARK: - CompositeNode

/// CompositeNode - A node in the composite task tree
///
/// Nodes are either operator nodes (AND, OR, M_OF_N) with children,
/// or leaf nodes that reference a task in the tasks table.
///
/// Matches TypeScript CompositeNode interface from @oybc/shared
struct CompositeNode: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var compositeTaskId: String      // FK to composite_tasks

    // Tree position
    var parentNodeId: String?        // FK to composite_nodes (nil for root)
    var nodeIndex: Int               // Order among siblings (0-based)

    // Node type
    var nodeType: CompositeNodeType

    // Operator node fields (only when nodeType == .operator)
    var operatorType: OperatorType?
    var threshold: Int?              // Required for M_OF_N

    // Leaf node fields (only when nodeType == .leaf)
    var taskId: String?              // FK to tasks
    var childCompositeTaskId: String? // FK to composite_tasks (nested composite)

    // Timestamps
    var createdAt: String            // ISO8601
    var updatedAt: String            // ISO8601

    // Sync metadata
    var lastSyncedAt: String?        // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String?           // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "composite_nodes"
    static let compositeTask = belongsTo(CompositeTask.self)
    static let task = belongsTo(Task.self,
                                using: ForeignKey(["taskId"]))
}

// MARK: - Supporting Types

/// Node type discriminator
enum CompositeNodeType: String, Codable, DatabaseValueConvertible {
    case `operator` = "operator"
    case leaf = "leaf"
}

/// Composite operator types
enum OperatorType: String, Codable, DatabaseValueConvertible {
    case and = "AND"
    case or = "OR"
    case mOfN = "M_OF_N"
}
