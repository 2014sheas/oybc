import XCTest
import GRDB
@testable import OYBC

/// The Getting Started step machine: each free lesson's script advances only on
/// its real control's event (Next on read-only steps), leaving saves the step,
/// resuming picks it up, and completion is written to the synced preferences.
@MainActor
final class TutorialCoordinatorTests: XCTestCase {

    private let userId = "u1"

    private func makeUser() -> User {
        let now = AppDatabase.currentTimestamp()
        return User(
            id: userId, email: "t@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    /// A coordinator over a fresh "real" test database holding the user row.
    private func makeCoordinator(progress: TutorialProgress = .empty) throws -> (TutorialCoordinator, AppDatabase) {
        let real = try AppDatabase.makeTestInstance()
        try real.saveUser(makeUser())
        return (TutorialCoordinator(userId: userId, database: real, progress: progress), real)
    }

    private func savedProgress(_ db: AppDatabase) throws -> TutorialProgress {
        try XCTUnwrap(db.fetchUser(id: userId)).decodedPreferences.tutorialProgress
    }

    // MARK: - Scripts

    private static let createTaskScript: [TutorialEvent] = [
        .tasksPlusTapped, .normalTaskCreated, .specialPanelOpened, .countingFieldsFilled, .countingTaskCreated,
    ]
    private static let createBoardScript: [TutorialEvent] = [
        .oneOffBoardStarted, .boardSizePicked, .setupNext, .sourcesSheetOpened, .poolsPicked, .tasksStepNext, .boardActivated,
    ]

    func test_createTask_advancesOnEachRealControlEvent() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for (index, event) in Self.createTaskScript.enumerated() {
            XCTAssertEqual(coach.session?.step, index)
            coach.handle(event)
        }
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    func test_createBoard_advancesOnEachRealControlEvent() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for (index, event) in Self.createBoardScript.enumerated() {
            XCTAssertEqual(coach.session?.step, index)
            coach.handle(event)
        }
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    func test_completeBoard_actionStepsAndReadOnlyNextSteps() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        coach.handle(.editEntered)            // 1 Edit
        coach.handle(.editSaved)              // 2 swap + Save
        coach.handle(.simpleSquareDone)       // 3 Stretch
        XCTAssertEqual(coach.session?.step, 3)
        XCTAssertTrue(coach.currentStepIsReadOnly, "step 4 (the Undo toast) is read-only")
        coach.next()                          // 4 Next
        coach.handle(.countingSheetOpened)    // 5 Read
        coach.handle(.countLogged)            // 6 chip
        XCTAssertEqual(coach.session?.step, 6)
        XCTAssertTrue(coach.currentStepIsReadOnly)
        coach.next()                          // 7 Next closes the sheet
        XCTAssertEqual(coach.session?.currentStep?.closesSquareSheet, true)
        coach.next()                          // 8 hold-menu Next
        XCTAssertEqual(coach.session?.step, 8)
        coach.handle(.bingoMomentClosed)      // 9 Tidy desk -> Bingo moment closes
        XCTAssertEqual(coach.session?.step, 9)
        XCTAssertEqual(coach.session?.phase, .running)
        coach.handle(.greenlogMomentClosed)   // 10 Greenlog closes
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    func test_wrongEventsAndNextOnActionStepsAreIgnored() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.handle(.normalTaskCreated)      // not the step's event
        coach.next()                          // action steps have no Next
        XCTAssertEqual(coach.session?.step, 0)
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.step, 1)
    }

    func test_eventsAreIgnoredWhileTheLeaveSheetIsUp() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.requestLeave()
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.step, 0)
        coach.keepGoing()
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.step, 1)
    }

    func test_greenlogClosingBeforeTheBingoBeatStillClosesTheLesson() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        coach.handle(.countLogged)
        coach.next(); coach.next()
        XCTAssertEqual(coach.session?.step, 8)
        coach.handle(.greenlogMomentClosed)
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    func test_momentOpenHidesTheLayerUntilItCloses() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        coach.setMomentOpen(true)
        XCTAssertEqual(coach.session?.momentOpen, true)
        coach.handle(.bingoMomentClosed)       // not this step's event, but it still un-hides
        XCTAssertEqual(coach.session?.momentOpen, false)
    }

    // MARK: - Copy that follows what the user did

    func test_loggedSummaryFoldsIntoTheStepCopy() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        coach.reportLog(summary: "22 of 20", finishedSquare: true)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.currentText, "22 of 20. The square is done; Undo stays here.")
    }

    func test_loggedSummaryOnAnUnfinishedSquareDoesNotClaimDone() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        coach.reportLog(summary: "13 of 20", finishedSquare: false)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.currentText, "13 of 20. Undo stays here.")
    }

    func test_poolSummaryFoldsIntoTheTapNextStep() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for event in Self.createBoardScript.prefix(4) { coach.handle(event) }
        coach.reportPool(summary: "Fitness fills eight squares")
        coach.handle(.poolsPicked)
        XCTAssertEqual(coach.currentText, "Fitness fills eight squares. Tap Next.")
    }

    // MARK: - Completion, leave, resume

    func test_completionIsSavedToTheSyncedPreferences() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for event in Self.createTaskScript { coach.handle(event) }
        XCTAssertEqual(coach.progress.state(of: .createTask), .done)
        XCTAssertEqual(try savedProgress(real).state(of: .createTask), .done)
        let user = try XCTUnwrap(real.fetchUser(id: userId))
        XCTAssertEqual(user.version, 2, "a preference write bumps the user version")
        let queued = try real.fetchPendingSyncItems()
        XCTAssertTrue(queued.contains { $0.entityType == "users" && $0.entityId == userId }, "progress rides the user doc's sync")
    }

    func test_finishCompletedLesson_handsTheLessonToTheBoardAndEndsTheSession() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for event in Self.createTaskScript { coach.handle(event) }
        coach.finishCompletedLesson()
        XCTAssertNil(coach.session)
        XCTAssertEqual(coach.justCompleted, .createTask)
        coach.consumeJustCompleted()
        XCTAssertNil(coach.justCompleted)
    }

    func test_leaveSavesTheStepAndResumeOpensThereWithTheResumedTag() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for event in Self.createBoardScript.prefix(3) { coach.handle(event) }
        coach.requestLeave()
        XCTAssertEqual(coach.session?.phase, .confirmingLeave)
        coach.leave()
        XCTAssertNil(coach.session)
        XCTAssertNil(coach.sandboxDatabase, "the sandbox is discarded on leave")
        XCTAssertEqual(coach.progress.state(of: .createBoard), .inProgress(step: 3))
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 3))

        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.step, 3)
        XCTAssertEqual(coach.session?.resumed, true)
        XCTAssertNotNil(coach.sandboxDatabase, "resume rebuilds the sandbox silently")
        coach.handle(.sourcesSheetOpened)
        XCTAssertEqual(coach.session?.resumed, false, "RESUMED tags only the first coach mark")
    }

    func test_leavingAtTheFirstStepSavesNothing() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.requestLeave()
        coach.leave()
        XCTAssertEqual(coach.progress, .empty)
    }

    func test_replayingADoneLessonStartsAtStepOneAndLeavingKeepsItDone() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        let (coach, _) = try makeCoordinator(progress: progress)
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(coach.session?.resumed, false)
        coach.handle(.tasksPlusTapped)
        coach.leave()
        XCTAssertEqual(coach.progress.state(of: .createTask), .done)
    }

    func test_proLessonsDoNotStartAndOnlyOneSessionRuns() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertFalse(coach.start(.multiStep))
        XCTAssertNil(coach.session)
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertFalse(coach.start(.createBoard), "a second lesson cannot start over a running one")
    }

    // MARK: - Card dismissal

    func test_cardCanOnlyBeDismissedOnceTheMiddleRowIsDone() throws {
        let (coach, real) = try makeCoordinator()
        coach.dismissCard()
        XCTAssertTrue(coach.progress.showsCard, "not allowed before the free row is done")
        var progress = TutorialProgress.empty
        for id in TutorialLessonID.middleRow { progress.set(id, .done) }
        coach.refresh(from: progress)
        coach.dismissCard()
        XCTAssertFalse(coach.progress.showsCard)
        XCTAssertTrue(try savedProgress(real).cardDismissed, "the dismissal is stored with the account")
    }

    func test_refreshTakesAProgressChangeThatArrivedFromSync() throws {
        let (coach, _) = try makeCoordinator()
        var remote = TutorialProgress.empty
        remote.set(.createBoard, .done)
        coach.refresh(from: remote)
        XCTAssertEqual(coach.progress.state(of: .createBoard), .done)
    }

    func test_signalsReflectTheRunningSession() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertEqual(coach.signals, .inactive)
        XCTAssertTrue(coach.start(.completeBoard))
        XCTAssertTrue(coach.signals.active)
        XCTAssertTrue(coach.signals.sandboxed)
        XCTAssertFalse(coach.signals.isCompleting)
        XCTAssertTrue(coach.start(.createTask) == false)
        coach.leave()
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertFalse(coach.signals.sandboxed, "lesson 1 writes real tasks, so nothing is sandboxed")
    }
}
