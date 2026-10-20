import XCTest
@testable import OYBC

/// Getting Started progress model: derived values, the lenient wire codec (the
/// Swift twin of `mergeTutorialProgress` in `@oybc/shared`) and the round trip
/// through the synced `UserPreferences` document.
final class TutorialProgressTests: XCTestCase {

    // MARK: - Derived values

    func test_empty_hasNothingDone() {
        let progress = TutorialProgress.empty
        XCTAssertEqual(progress.doneCount, 0)
        XCTAssertFalse(progress.middleRowDone)
        XCTAssertFalse(progress.isComplete)
        XCTAssertFalse(progress.canDismissCard)
        XCTAssertTrue(progress.showsCard)
        XCTAssertEqual(progress.state(of: .createTask), .notStarted)
        XCTAssertEqual(progress.nextLesson, .createTask)
    }

    func test_middleRowDone_needsAllThreeFreeLessons() {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        progress.set(.createBoard, .done)
        XCTAssertFalse(progress.middleRowDone)
        XCTAssertFalse(progress.canDismissCard)
        progress.set(.completeBoard, .done)
        XCTAssertTrue(progress.middleRowDone)
        XCTAssertTrue(progress.canDismissCard)
        XCTAssertEqual(progress.doneCount, 3)
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(progress.nextLesson, .multiStep, "after the free row the next lesson is the first Pro square")
    }

    func test_isComplete_onlyWhenAllNineAreDone() {
        var progress = TutorialProgress.empty
        for id in TutorialLessonID.allCases { progress.set(id, .done) }
        XCTAssertEqual(progress.doneCount, 9)
        XCTAssertTrue(progress.isComplete)
        XCTAssertNil(progress.nextLesson)
    }

    func test_inProgressIsNotCountedDone() {
        var progress = TutorialProgress.empty
        progress.set(.createBoard, .inProgress(step: 3))
        XCTAssertEqual(progress.doneCount, 0)
        XCTAssertEqual(progress.state(of: .createBoard), .inProgress(step: 3))
    }

    func test_setNotStarted_removesTheEntry() {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .inProgress(step: 2))
        progress.set(.createTask, .notStarted)
        XCTAssertTrue(progress.lessons.isEmpty)
    }

    func test_gridOrderAndFreeRow() {
        XCTAssertEqual(TutorialLessonID.allCases.count, 9)
        XCTAssertEqual(TutorialLessonID.middleRow.map(\.gridIndex), [3, 4, 5])
        XCTAssertEqual(TutorialLessonID.allCases.filter(\.isFree).count, 3)
        XCTAssertEqual(TutorialLessonID.allCases.map(\.rawValue), [
            "multiStep", "repeatingBoards", "mixSources", "createTask", "createBoard",
            "completeBoard", "sharedCounters", "biggerWindows", "achievements",
        ])
    }

    // MARK: - Codec

    private func encoded(_ progress: TutorialProgress) throws -> [String: Any] {
        let data = try JSONEncoder().encode(progress)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_encode_matchesTheSharedWireShape() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        progress.set(.createBoard, .inProgress(step: 3))
        progress.cardDismissed = true
        let wire = try encoded(progress)
        XCTAssertEqual(wire["cardDismissed"] as? Bool, true)
        let lessons = try XCTUnwrap(wire["lessons"] as? [String: [String: Any]])
        XCTAssertEqual(lessons["createTask"]?["status"] as? String, "done")
        XCTAssertNil(lessons["createTask"]?["step"])
        XCTAssertEqual(lessons["createBoard"]?["status"] as? String, "inProgress")
        XCTAssertEqual(lessons["createBoard"]?["step"] as? Int, 3)
    }

    func test_roundTrip() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        progress.set(.completeBoard, .inProgress(step: 7))
        progress.cardDismissed = true
        let data = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(TutorialProgress.self, from: data), progress)
    }

    func test_decode_dropsMalformedEntriesAndKeepsTheRest() throws {
        let json = """
        {"lessons":{
          "a":{"status":"inProgress","step":-1},
          "b":{"status":"inProgress"},
          "c":{"status":"weird"},
          "d":"done",
          "e":{"status":"done"},
          "createBoard":{"status":"inProgress","step":2}
        },"cardDismissed":"yes"}
        """
        let progress = try JSONDecoder().decode(TutorialProgress.self, from: Data(json.utf8))
        // Malformed KNOWN entries drop; an unknown status stays opaque.
        XCTAssertEqual(progress.lessons["e"], .done)
        XCTAssertEqual(progress.lessons["createBoard"], .inProgress(step: 2))
        XCTAssertNotNil(progress.lessons["c"])
        XCTAssertNil(progress.lessons["a"]); XCTAssertNil(progress.lessons["b"]); XCTAssertNil(progress.lessons["d"])
        XCTAssertFalse(progress.cardDismissed, "a non-boolean dismissal falls back to false")
    }

    func test_decode_keepsUnknownLessonIdsForForwardCompat() throws {
        let json = #"{"lessons":{"someFutureLesson":{"status":"done"}},"cardDismissed":false}"#
        let progress = try JSONDecoder().decode(TutorialProgress.self, from: Data(json.utf8))
        XCTAssertEqual(progress.lessons["someFutureLesson"], .done)
        XCTAssertEqual(progress.doneCount, 0, "unknown ids never count toward the nine")
        let again = try JSONDecoder().decode(TutorialProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(again.lessons["someFutureLesson"], .done, "an older client round-trips a newer lesson")
    }

    func test_unknownStatusRoundTripsVerbatimAndCountsAsNotStarted() throws {
        let json = #"{"lessons":{"createTask":{"status":"paused","note":"x","n":2}},"cardDismissed":false}"#
        let progress = try JSONDecoder().decode(TutorialProgress.self, from: Data(json.utf8))
        XCTAssertEqual(progress.state(of: .createTask), .notStarted)
        let wire = try encoded(progress)
        let lesson = try XCTUnwrap((wire["lessons"] as? [String: [String: Any]])?["createTask"])
        XCTAssertEqual(lesson["status"] as? String, "paused")
        XCTAssertEqual(lesson["note"] as? String, "x")
        XCTAssertEqual(lesson["n"] as? Int, 2)
    }

    // MARK: - Union (twin of unionTutorialProgress)

    func test_union_doneBeatsInProgressAndHigherStepWinsInBothDirections() {
        var a = TutorialProgress.empty
        a.set(.createTask, .done); a.set(.createBoard, .inProgress(step: 2)); a.set(.completeBoard, .inProgress(step: 5))
        var b = TutorialProgress.empty
        b.set(.createTask, .inProgress(step: 4)); b.set(.createBoard, .inProgress(step: 6)); b.set(.completeBoard, .inProgress(step: 1))
        for merged in [TutorialProgress.union(local: a, incoming: b), TutorialProgress.union(local: b, incoming: a)] {
            XCTAssertEqual(merged.state(of: .createTask), .done)
            XCTAssertEqual(merged.state(of: .createBoard), .inProgress(step: 6))
            XCTAssertEqual(merged.state(of: .completeBoard), .inProgress(step: 5))
        }
    }

    func test_union_keepsOneSidedLessonsOrsTheDismissalAndPrefersKnownOverOpaque() throws {
        var a = TutorialProgress.empty
        a.set(.createTask, .done)
        var b = TutorialProgress.empty
        b.set(.createBoard, .inProgress(step: 1)); b.cardDismissed = true
        let merged = TutorialProgress.union(local: a, incoming: b)
        XCTAssertEqual(merged.doneCount, 1)
        XCTAssertEqual(merged.state(of: .createBoard), .inProgress(step: 1))
        XCTAssertTrue(merged.cardDismissed)

        let opaque = try JSONDecoder().decode(TutorialProgress.self, from: Data(#"{"lessons":{"createTask":{"status":"paused"}}}"#.utf8))
        XCTAssertEqual(TutorialProgress.union(local: opaque, incoming: a).state(of: .createTask), .done)
        XCTAssertNotNil(TutorialProgress.union(local: opaque, incoming: .empty).lessons["createTask"])
    }

    func test_preferencesHelpers_readAndReplaceProgressInBothShapes() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        var prefs = UserPreferences.defaults
        prefs.tutorialProgress = progress
        let json = try XCTUnwrap(User.encodePreferences(prefs))
        XCTAssertEqual(TutorialProgress.fromPreferences(json), progress)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertEqual(TutorialProgress.fromPreferences(dict), progress)
        XCTAssertNil(TutorialProgress.fromPreferences(nil))
        var other = TutorialProgress.empty
        other.set(.createBoard, .done)
        let replaced = try XCTUnwrap(TutorialProgress.replacing(in: json, with: other))
        XCTAssertEqual(TutorialProgress.fromPreferences(replaced), other)
        XCTAssertEqual(replaced["weekStartDay"] as? String, "monday", "other preference fields are kept")
    }

    func test_decode_emptyOrWrongContainerYieldsEmpty() throws {
        for json in ["{}", #"{"lessons":"nope"}"#, #"{"lessons":[1,2]}"#] {
            let progress = try JSONDecoder().decode(TutorialProgress.self, from: Data(json.utf8))
            XCTAssertEqual(progress, .empty, json)
        }
    }

    // MARK: - UserPreferences integration

    func test_preferences_withoutTheKeyDecodeToEmpty() throws {
        // A user document written before the field existed.
        let json = """
        {"weekStartDay":"monday","defaultBoardSize":5,"defaultCenterType":"free","defaultTimeframe":"custom",
         "defaultRandomize":true,"theme":"system","recurringDailyEnabled":true,"recurringWeeklyEnabled":true,
         "recurringMonthlyEnabled":true,"recurringYearlyEnabled":true}
        """
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.tutorialProgress, .empty)
    }

    func test_preferences_roundTripCarriesProgress() throws {
        var prefs = UserPreferences.defaults
        prefs.tutorialProgress.set(.createTask, .done)
        prefs.tutorialProgress.cardDismissed = true
        let json = try XCTUnwrap(User.encodePreferences(prefs))
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tutorialProgress, prefs.tutorialProgress)
    }

    func test_preferences_malformedProgressFallsBackWithoutLosingOtherFields() throws {
        let json = """
        {"weekStartDay":"sunday","defaultBoardSize":3,"defaultCenterType":"none","defaultTimeframe":"weekly",
         "defaultRandomize":false,"theme":"dark","recurringDailyEnabled":false,"recurringWeeklyEnabled":true,
         "recurringMonthlyEnabled":true,"recurringYearlyEnabled":true,"tutorialProgress":"garbage"}
        """
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.tutorialProgress, .empty)
        XCTAssertEqual(prefs.weekStartDay, .sunday)
        XCTAssertEqual(prefs.theme, .dark)
        XCTAssertFalse(prefs.recurringDailyEnabled)
    }

    // MARK: - Copy

    func test_statusLine() {
        XCTAssertEqual(TutorialProgress.empty.statusLine(activeLesson: nil, activeStep: nil), "Tap a square to begin")
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        XCTAssertEqual(progress.statusLine(activeLesson: nil, activeStep: nil), "8 to go")
        XCTAssertEqual(progress.statusLine(activeLesson: .createBoard, activeStep: 1), "Create a board · step 2 of 7")
        progress.set(.createBoard, .done)
        progress.set(.completeBoard, .done)
        XCTAssertEqual(progress.statusLine(activeLesson: nil, activeStep: nil), "Bingo · middle row")
        for id in TutorialLessonID.allCases { progress.set(id, .done) }
        XCTAssertEqual(progress.statusLine(activeLesson: nil, activeStep: nil), "Greenlog")
    }

    func test_catalogCopy() {
        XCTAssertEqual(TutorialCatalog.titles, [
            "Multi-step tasks", "Repeating boards", "Mix your sources",
            "Create a task", "Create a board", "Complete a board",
            "Shared counters", "Bigger windows", "Achievements",
        ])
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).steps.count, 5)
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).steps.count, 7)
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).steps.count, 10)
        XCTAssertTrue(TutorialCatalog.lessons.filter { !$0.isFree }.allSatisfy { $0.steps.isEmpty && $0.glyph == nil })
    }
}
