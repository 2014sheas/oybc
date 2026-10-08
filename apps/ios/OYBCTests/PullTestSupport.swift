import Foundation
@testable import OYBC

/// In-memory `PullDocumentSource` for the pull-orchestration tests: serves
/// docs per collection with Firestore's `_syncedAt >= since` semantics,
/// records every call in order, can throw for one collection, and keeps each
/// listener's `onChange` so a test can deliver a snapshot.
final class FakePullSource: PullDocumentSource, @unchecked Sendable {
    struct FetchCall: Equatable { let collection: String; let since: PullWatermark? }

    private let lock = NSLock()
    private var docsByCollection: [String: [[String: Any]]]
    private var userDoc: [String: Any]?
    private var failCollection: String?
    private var _events: [String] = []
    private var _fetches: [FetchCall] = []
    private var _listenSince: [String: PullWatermark] = [:]
    private var _listeners: [String: (PullDocs) -> Void] = [:]

    init(docsByCollection: [String: [[String: Any]]], userDoc: [String: Any]? = nil, failCollection: String? = nil) {
        self.docsByCollection = docsByCollection
        self.userDoc = userDoc
        self.failCollection = failCollection
    }

    /// Every call, in order: `fetch:<collection>`, `listen:<collection>`, `fetch:users`, `listen:users`.
    var events: [String] { lock.withLock { _events } }
    var fetches: [FetchCall] { lock.withLock { _fetches } }
    var listenSince: [String: PullWatermark] { lock.withLock { _listenSince } }

    /// Delivers a snapshot to `collection`'s listener (if attached).
    func deliver(_ docs: [[String: Any]], to collection: String) {
        let onChange = lock.withLock { _listeners[collection] }
        onChange?(PullDocs(docs: docs))
    }

    func fetchUserDoc(userId: String) async throws -> [String: Any]? {
        lock.withLock { _events.append("fetch:users"); return userDoc }
    }

    func fetchCollection(userId: String, collection: String, since: PullWatermark?) async throws -> PullDocs {
        try lock.withLock {
            _events.append("fetch:\(collection)")
            _fetches.append(FetchCall(collection: collection, since: since))
            if collection == failCollection { throw URLError(.notConnectedToInternet) }
            let all = docsByCollection[collection] ?? []
            guard let since else { return PullDocs(docs: all) }
            return PullDocs(docs: all.filter { (PullWatermark(syncedAtValue: $0["_syncedAt"]).map { $0 >= since }) ?? false })
        }
    }

    func listenUserDoc(userId: String, onChange: @escaping ([String: Any]) -> Void) -> PullListener {
        lock.withLock { _events.append("listen:users") }
        return PullListener {}
    }

    func listenCollection(
        userId: String, collection: String, since: PullWatermark,
        onChange: @escaping (PullDocs) -> Void
    ) -> PullListener {
        lock.withLock {
            _events.append("listen:\(collection)")
            _listenSince[collection] = since
            _listeners[collection] = onChange
        }
        return PullListener { [weak self] in self?.lock.withLock { self?._listeners[collection] = nil } }
    }
}

/// Synthetic remote dataset shaped like a real account: `boards` live 3×3
/// boards, each with its own 9 NORMAL tasks placed on it and an in-window
/// completion event for cells 0, 1, 2 — so every board's CORRECT derivation is
/// known up front: 3 completed, 1 line, `row_0`. Every doc carries a distinct,
/// increasing `_syncedAt` (a `Date`, which `PullWatermark` reads).
struct PullFixture {
    static let userId = "u1"
    static let start = "2026-07-01T00:00:00.000Z"
    static let end = "2099-12-31T23:59:59.999Z"
    static let inWindow = "2026-07-02T12:00:00.000Z"
    static let expectedCompleted = 3
    static let expectedLineIds = ["row_0"]

    let boardIds: [String]
    private(set) var docs: [String: [[String: Any]]] = [:]
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    /// A deterministic UUID-format id (the pull validator rejects anything else).
    static func uuid(_ kind: Int, _ n: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", kind, n)
    }

    init(boards: Int, userId: String = PullFixture.userId) {
        boardIds = (0..<boards).map { Self.uuid(1, $0) }
        for (b, boardId) in boardIds.enumerated() {
            add("boards", [
                "id": boardId, "userId": userId, "name": "B\(b)", "status": "active",
                "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
                "startDate": Self.start, "endDate": Self.end,
                "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
                "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
                "createdAt": Self.start, "updatedAt": Self.start, "version": 1, "isDeleted": false,
            ])
            for cell in 0..<9 {
                let n = b * 9 + cell
                let taskId = Self.uuid(2, n)
                add("tasks", [
                    "id": taskId, "userId": userId, "title": "T\(n)", "type": "normal",
                    "isCompleted": cell < 3, "totalCompletions": 0, "totalInstances": 0,
                    "createdAt": Self.start, "updatedAt": Self.start, "version": 1, "isDeleted": false,
                ])
                add("boardTasks", [
                    "id": Self.uuid(3, n), "boardId": boardId, "taskId": taskId,
                    "row": cell / 3, "col": cell % 3, "isCenter": false,
                    "createdAt": Self.start, "updatedAt": Self.start, "version": 1, "isDeleted": false,
                ])
                if cell < 3 {
                    add("taskEvents", [
                        "id": Self.uuid(4, n), "userId": userId, "taskId": taskId, "kind": "completion",
                        "occurredAt": Self.inWindow, "createdAt": Self.inWindow, "updatedAt": Self.inWindow,
                        "version": 1, "isDeleted": false,
                    ])
                }
            }
        }
    }

    private mutating func add(_ collection: String, _ doc: [String: Any]) {
        clock = clock.addingTimeInterval(0.001)
        var stamped = doc
        stamped["_syncedAt"] = clock
        docs[collection, default: []].append(stamped)
    }

    /// The highest `_syncedAt` among `collection`'s docs.
    func maxSyncedAt(_ collection: String) -> PullWatermark? {
        nextPullWatermark(nil, (docs[collection] ?? []).map { PullWatermark(syncedAtValue: $0["_syncedAt"]) })
    }
}

/// Records the longest gap between main-actor heartbeats (every ~10 ms) while
/// work runs — the longest the main thread was blocked.
@MainActor
final class MainThreadHeartbeat {
    private var last = Date()
    private(set) var maxGap: TimeInterval = 0
    private var running = true
    private var task: _Concurrency.Task<Void, Never>?

    func start() {
        last = Date()
        task = _Concurrency.Task { @MainActor [weak self] in
            while let self, self.running {
                self.tick()
                try? await _Concurrency.Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func tick() {
        let now = Date()
        maxGap = max(maxGap, now.timeIntervalSince(last))
        last = now
    }

    func stop() async {
        tick()
        running = false
        await task?.value
    }
}

/// A push-side store that accepts everything — so a test that runs the real
/// orchestration (`start`) never reaches Firebase (no `FirebaseApp` here).
struct NullDocStore: FirestoreDocStore {
    func fetch(path: String) async throws -> [String: Any]? { nil }
    func write(path: String, data: [String: Any]) async throws {}
}
