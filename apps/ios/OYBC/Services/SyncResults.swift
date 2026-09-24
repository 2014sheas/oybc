import Foundation

// Result + event value types for `SyncService`, moved out of SyncService.swift
// verbatim (2026-09 audit T1) to keep that allowlisted god-file under its
// frozen size cap (ROADMAP B6).

/// Summary of a push sync operation.
public struct PushResult {
    /// Number of documents successfully pushed to Firestore.
    public var pushed: Int = 0
    /// Number of conflicts resolved in favour of the remote document.
    public var conflicts: Int = 0
    /// Number of items that failed to push.
    public var failed: Int = 0
    /// Human-readable log lines for each processed item.
    public var details: [String] = []
}

/// Summary of a pull sync operation.
public struct PullResult {
    /// Number of documents pulled from Firestore into local DB.
    public var pulled: Int = 0
    /// Number of conflicts resolved in favour of the local document.
    public var conflicts: Int = 0
    /// Human-readable log lines for each processed item.
    public var details: [String] = []
}

/// Combined result of a full push + pull sync cycle.
public struct SyncResult {
    public let push: PushResult
    public let pull: PullResult
}

/// A single event in the sync log, displayed in the playground dashboard.
public struct SyncEvent: Identifiable {
    public let id: UUID = UUID()
    public let timestamp: Date
    public let message: String
}
