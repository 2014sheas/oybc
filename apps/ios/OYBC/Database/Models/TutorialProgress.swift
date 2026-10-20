import Foundation

// MARK: - TutorialLessonID

/// The nine Getting Started lessons, in tutorial-board grid order (row-major):
/// row 0 = Multi-step tasks · Repeating boards · Mix your sources, row 1 = the
/// three free lessons (Create a task · Create a board · Complete a board),
/// row 2 = Shared counters · Bigger windows · Achievements. Raw values are the
/// wire ids stored in the synced `tutorialProgress` preference.
enum TutorialLessonID: String, CaseIterable, Codable {
    case multiStep
    case repeatingBoards
    case mixSources
    case createTask
    case createBoard
    case completeBoard
    case sharedCounters
    case biggerWindows
    case achievements

    /// Total lessons on the board (the progress denominator).
    static let total = allCases.count

    /// The free middle row, left to right — completing all three is a Bingo.
    static let middleRow: [TutorialLessonID] = [.createTask, .createBoard, .completeBoard]

    /// True for the three lessons that ship free (the rest are Pro placeholders).
    var isFree: Bool { Self.middleRow.contains(self) }

    /// 0-8 grid slot (row-major).
    var gridIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - TutorialLessonState

/// One lesson's saved state. `notStarted` is the absence of an entry on the wire.
enum TutorialLessonState: Equatable {
    case notStarted
    /// Left mid-lesson at the 0-based `step`; tapping the square resumes there.
    case inProgress(step: Int)
    case done
}

// MARK: - TutorialProgress

/// Getting Started tutorial progress — synced inside the user's preferences
/// document (`UserPreferences.tutorialProgress`), replacing the device-local
/// `TutorialProgressStore`. Mirrors `TutorialProgress` /
/// `mergeTutorialProgress` in `@oybc/shared` (`types/user.ts`).
///
/// Wire shape: `{ "lessons": { "<id>": { "status": "inProgress", "step": 2 } |
/// { "status": "done" } }, "cardDismissed": false }`. Lesson ids are open
/// strings so a lesson a newer client wrote survives a pass through this one.
struct TutorialProgress: Codable, Equatable {
    /// Saved lesson states keyed by wire id; a missing key is `notStarted`.
    var lessons: [String: TutorialLessonState]
    /// Whether the Boards-tab card was dismissed (only allowed once the middle row is done).
    var cardDismissed: Bool

    /// No lessons touched, card visible.
    static let empty = TutorialProgress(lessons: [:], cardDismissed: false)

    init(lessons: [String: TutorialLessonState] = [:], cardDismissed: Bool = false) {
        self.lessons = lessons
        self.cardDismissed = cardDismissed
    }

    // MARK: Derived

    /// The saved state of a lesson.
    func state(of id: TutorialLessonID) -> TutorialLessonState {
        lessons[id.rawValue] ?? .notStarted
    }

    /// Lessons finished (of the nine known ids).
    var doneCount: Int {
        TutorialLessonID.allCases.filter { state(of: $0) == .done }.count
    }

    /// All three free lessons are done — a Bingo on the tutorial board.
    var middleRowDone: Bool {
        TutorialLessonID.middleRow.allSatisfy { state(of: $0) == .done }
    }

    /// Every one of the nine lessons is done (a Greenlog).
    var isComplete: Bool { doneCount >= TutorialLessonID.total }

    /// The Boards-tab card may only be dismissed once the middle row is done.
    var canDismissCard: Bool { middleRowDone }

    /// True when the pinned Boards-tab card should show.
    var showsCard: Bool { !cardDismissed }

    /// The first lesson (grid order of the free row first, then the rest) not yet done.
    var nextLesson: TutorialLessonID? {
        (TutorialLessonID.middleRow + TutorialLessonID.allCases.filter { !$0.isFree })
            .first { state(of: $0) != .done }
    }

    // MARK: Mutations

    /// Sets (or clears, for `.notStarted`) a lesson's state.
    mutating func set(_ id: TutorialLessonID, _ newState: TutorialLessonState) {
        if newState == .notStarted {
            lessons.removeValue(forKey: id.rawValue)
        } else {
            lessons[id.rawValue] = newState
        }
    }

    // MARK: Codable (forward-compatible, lenient)

    private enum CodingKeys: String, CodingKey { case lessons, cardDismissed }

    /// One lesson entry on the wire.
    private struct Entry: Codable {
        let status: String
        let step: Int?
    }

    /// Lenient decode: a malformed lesson entry is dropped (never fails the
    /// whole preferences document), a missing/odd container yields `.empty`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var parsed: [String: TutorialLessonState] = [:]
        if let raw = try? c.decode([String: LossyEntry].self, forKey: .lessons) {
            for (id, lossy) in raw {
                guard let entry = lossy.entry else { continue }
                switch entry.status {
                case "done":
                    parsed[id] = .done
                case "inProgress":
                    if let step = entry.step, step >= 0 { parsed[id] = .inProgress(step: step) }
                default:
                    continue
                }
            }
        }
        self.lessons = parsed
        self.cardDismissed = (try? c.decode(Bool.self, forKey: .cardDismissed)) ?? false
    }

    /// Wraps `Entry` so one undecodable value doesn't fail the dictionary.
    private struct LossyEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var wire: [String: Entry] = [:]
        for (id, state) in lessons {
            switch state {
            case .notStarted: continue
            case .done: wire[id] = Entry(status: "done", step: nil)
            case .inProgress(let step): wire[id] = Entry(status: "inProgress", step: step)
            }
        }
        try c.encode(wire, forKey: .lessons)
        try c.encode(cardDismissed, forKey: .cardDismissed)
    }
}
