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
        XCTAssertEqual(user.version, 6, "steps 2-5 and the completion each write once (the first step never does)")
        let queued = try real.fetchPendingSyncItems()
        XCTAssertTrue(queued.contains { $0.entityType == "users" && $0.entityId == userId }, "progress rides the user doc's sync")
    }

    func test_finishCompletedLesson_handsTheLessonToTheBoardAndEndsTheSession() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for event in Self.createTaskScript { coach.handle(event) }
        coach.finishCompletedLesson()
        XCTAssertTrue(coach.isClosing)
        XCTAssertNotNil(coach.session, "the session stays until the cover has finished dismissing")
        XCTAssertEqual(coach.justCompleted, .createTask)
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertEqual(coach.justCompleted, .createTask, "the board still plays the pop")
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
        XCTAssertNotNil(coach.sandboxDatabase, "the sandbox lives until the cover is gone")
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertNil(coach.sandboxDatabase, "the sandbox is discarded once the cover has dismissed")
        XCTAssertEqual(coach.progress.state(of: .createBoard), .inProgress(step: 3))
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 3))

        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.step, 0, "the wizard's state cannot be rebuilt, so lesson 2 reopens at step 1")
        XCTAssertEqual(coach.session?.resumed, true, "the RESUMED tag still shows")
        XCTAssertNotNil(coach.sandboxDatabase, "resume rebuilds the sandbox silently")
        coach.handle(.oneOffBoardStarted)
        XCTAssertEqual(coach.session?.resumed, false, "RESUMED tags only the first coach mark")
        XCTAssertEqual(coach.progress.state(of: .createBoard), .inProgress(step: 3), "a saved place is never lowered")
    }

    func test_leavingAtTheFirstStepSavesNothing() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.requestLeave()
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(coach.progress, .empty)
    }

    func test_replayingADoneLessonStartsAtStepOneAndLeavingKeepsItDone() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        let (coach, real) = try makeCoordinator(progress: progress)
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(coach.session?.resumed, false)
        let versionBefore = try XCTUnwrap(real.fetchUser(id: userId)).version
        coach.handle(.tasksPlusTapped)
        coach.handle(.normalTaskCreated)
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(coach.progress.state(of: .createTask), .done)
        XCTAssertEqual(try XCTUnwrap(real.fetchUser(id: userId)).version, versionBefore, "replaying writes nothing")
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
        coach.stageDidDismiss()
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertFalse(coach.signals.sandboxed, "lesson 1 writes real tasks, so nothing is sandboxed")
    }

    // MARK: - Persistence on every step

    func test_everyAdvanceSavesThePlaceWithoutLeaving() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        let v0 = try XCTUnwrap(real.fetchUser(id: userId)).version
        for event in Self.createBoardScript.prefix(3) { coach.handle(event) }
        // An app kill here (no Leave) still keeps "Your place is saved".
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 3))
        XCTAssertEqual(try XCTUnwrap(real.fetchUser(id: userId)).version, v0 + 3, "advancing to steps 1, 2 and 3 each writes once; step 0 never does")
        coach.leave()
        XCTAssertEqual(try XCTUnwrap(real.fetchUser(id: userId)).version, v0 + 3, "leaving with nothing new writes nothing")
    }

    func test_aStageDismissedWithoutLeaveEndsTheSessionAndSavesThePlace() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        coach.handle(.editEntered)
        coach.handle(.editSaved)
        // e.g. Archive from the Edit BOARD section dismissed the cover.
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertNil(coach.sandboxDatabase)
        XCTAssertEqual(try savedProgress(real).state(of: .completeBoard), .inProgress(step: 2))
        XCTAssertTrue(coach.start(.createTask), "lessons stay startable afterwards")
    }

    // MARK: - Resume consistency (lesson 3 reseeds)

    private func resumeFacts(saved: Int) throws -> (step: Int, stretchDone: Bool, read: CountValue, tidyDone: Bool) {
        var progress = TutorialProgress.empty
        progress.set(.completeBoard, .inProgress(step: saved))
        let (coach, _) = try makeCoordinator(progress: progress)
        XCTAssertTrue(coach.start(.completeBoard))
        let session = try XCTUnwrap(coach.session)
        let db = try XCTUnwrap(coach.sandboxDatabase)
        let boardId = try XCTUnwrap(session.sampleBoardId)
        let vm = BoardPlayViewModel(boardId: boardId, userId: userId, database: db)
        vm.reload()
        let deadline = Date().addingTimeInterval(30)
        while !(vm.board?.id == boardId && vm.boardTasks.count == 9 && !vm.allTasks.isEmpty), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        func task(_ title: String) throws -> Task { try XCTUnwrap(vm.allTasks.first { $0.title == title }) }
        return (
            session.step,
            vm.windowedCompletedValue(try task("Stretch")),
            vm.windowedCountValue(try task("Read 20 pages")),
            vm.windowedCompletedValue(try task("Tidy desk"))
        )
    }

    func test_lessonThreeResumeReseedsTheBoardToTheSavedStepAndSkipsStepsWhoseControlIsGone() throws {
        var facts = try resumeFacts(saved: 3)   // the Undo toast is gone -> step 5
        XCTAssertEqual(facts.step, 4)
        XCTAssertTrue(facts.stretchDone)
        XCTAssertEqual(facts.read, 12)
        facts = try resumeFacts(saved: 5)       // the sheet is closed -> reopen Read
        XCTAssertEqual(facts.step, 4)
        XCTAssertEqual(facts.read, 12)
        facts = try resumeFacts(saved: 6)       // Read already 22/20, sheet closed
        XCTAssertEqual(facts.step, 7)
        XCTAssertEqual(facts.read, 22)
        XCTAssertFalse(facts.tidyDone)
        facts = try resumeFacts(saved: 9)       // the Bingo already happened
        XCTAssertEqual(facts.step, 9)
        XCTAssertTrue(facts.tidyDone)
        facts = try resumeFacts(saved: 1)       // the Edit panel is not open
        XCTAssertEqual(facts.step, 0)
        XCTAssertFalse(facts.stretchDone)
    }

    func test_lessonOneAndTwoReopenAtStepOneWithTheResumedTag() throws {
        for lesson in [TutorialLessonID.createTask, .createBoard] {
            var progress = TutorialProgress.empty
            progress.set(lesson, .inProgress(step: 3))
            let (coach, _) = try makeCoordinator(progress: progress)
            XCTAssertTrue(coach.start(lesson))
            XCTAssertEqual(coach.session?.step, 0)
            XCTAssertEqual(coach.session?.resumed, true)
        }
    }

    // MARK: - Finale lights every incomplete square

    func test_finaleLightsEveryIncompleteSquareWithTheRealRemainingCount() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        coach.handle(.countLogged)
        coach.next(); coach.next()
        coach.handle(.bingoMomentClosed)
        XCTAssertEqual(coach.session?.step, 9)
        XCTAssertEqual(coach.currentText, "Three left. Complete them for a Greenlog.", "static fallback before the board reports")
        coach.reportIncomplete(slots: [0, 1, 6, 8])
        XCTAssertEqual(coach.session?.litAnchors, [.square(0), .square(1), .square(6), .square(8)], "a square the user undid is lit too")
        XCTAssertEqual(coach.currentText, "Four left. Complete them for a Greenlog.")
        coach.reportIncomplete(slots: [1, 6])
        XCTAssertEqual(coach.currentText, "Two left. Complete them for a Greenlog.")
        coach.reportIncomplete(slots: [6])
        XCTAssertEqual(coach.currentText, "One left. Complete it for a Greenlog.")
    }

    /// Undo (the toast, the sheet strip) is usable throughout the lesson, so the
    /// finale must reach the Greenlog even from an un-done square.
    func test_undoThenFinaleStillReachesTheGreenlog() throws {
        let sandbox = try AppDatabase.seedTutorialSandbox(lesson: .completeBoard, user: makeUser())
        let db = sandbox.database
        let boardId = try XCTUnwrap(sandbox.sampleBoardId)
        let vm = BoardPlayViewModel(boardId: boardId, userId: userId, database: db)
        vm.reload()
        func wait(_ p: () -> Bool) { let d = Date().addingTimeInterval(30); while !p(), Date() < d { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } }
        wait { vm.board?.id == boardId && vm.boardTasks.count == 9 && !vm.allTasks.isEmpty }
        func placement(_ title: String) throws -> (BoardTask, Task) {
            let task = try XCTUnwrap(vm.allTasks.first { $0.title == title })
            return (try XCTUnwrap(vm.boardTasks.first { $0.taskId == task.id }), task)
        }
        func settle() { wait { !vm.isProcessing } }

        vm.handleNormalTap(boardTask: try placement("Stretch").0); settle()
        let (readBT, read) = try placement("Read 20 pages")
        vm.handleCountingTap(boardTask: readBT, task: read, amount: 10, persistAsDefault: false); settle()
        vm.handleNormalTap(boardTask: try placement("Tidy desk").0); settle()
        // Undo Read (the sheet's Undo strip) and Stretch (the toast's Undo).
        vm.handleCountingDecrement(boardTask: readBT, task: try placement("Read 20 pages").1, amount: 10, persistAsDefault: false); settle()
        vm.handleNormalTap(boardTask: try placement("Stretch").0); settle()
        wait { vm.tutorialIncompleteSlots().count >= 5 }
        let slots = vm.tutorialIncompleteSlots()
        XCTAssertEqual(Set(slots), [
            TutorialCatalog.SampleSlot.stretch, TutorialCatalog.SampleSlot.read, TutorialCatalog.SampleSlot.callMom,
            TutorialCatalog.SampleSlot.journal, TutorialCatalog.SampleSlot.noSugar,
        ])

        // The finale lights all of them; finishing every one reaches the Greenlog.
        vm.handleNormalTap(boardTask: try placement("Stretch").0); settle()
        vm.handleCountingTap(boardTask: readBT, task: try placement("Read 20 pages").1, amount: 8, persistAsDefault: false); settle()
        vm.handleNormalTap(boardTask: try placement("Call mom").0); settle()
        vm.handleNormalTap(boardTask: try placement("Journal").0); settle()
        vm.handleNormalTap(boardTask: try placement("No sugar").0); settle()
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: boardId)).completedTasks, 9)
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: boardId)).status, .completed)
        wait { vm.tutorialIncompleteSlots().isEmpty }
        XCTAssertTrue(vm.tutorialIncompleteSlots().isEmpty)
    }

    // MARK: - The board gets ahead of the script

    /// Tidy desk marked done from the hold menu on the read-only "Hold a square"
    /// step: the Bingo moment closes before step 9 waits for it, so the lesson
    /// jumps past step 9 to the finale instead of asking for a done square.
    func test_bingoClosingOnTheHoldStepSkipsTheCompleteTidyDeskStep() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        coach.handle(.countLogged)
        coach.next()
        XCTAssertEqual(coach.session?.step, 7, "the hold-menu step")
        coach.handle(.bingoMomentClosed)
        XCTAssertEqual(coach.session?.step, 9, "straight to the finale")
        XCTAssertEqual(coach.session?.phase, .running)
    }

    // MARK: - A lit sheet closed early steps back

    func test_sourcesSheetClosedWithoutAPoolLightsTheEntryRowAgain() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for event in Self.createBoardScript.prefix(4) { coach.handle(event) }
        XCTAssertEqual(coach.session?.step, 4, "the pool rows")
        coach.handle(.sourcesSheetClosedEmpty)
        XCTAssertEqual(coach.session?.step, 3, "back to Add from a pool or board")
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 4), "the saved place is never lowered")
        coach.handle(.sourcesSheetOpened)
        coach.reportPool(summary: "Fitness fills eight squares")
        coach.handle(.poolsPicked)
        XCTAssertEqual(coach.session?.step, 5)
        coach.handle(.sourcesSheetClosedEmpty)
        XCTAssertEqual(coach.session?.step, 5, "means nothing once the pool is in")
    }

    func test_squareSheetSwipedAwayStepsBackToReadOrOnToTheHoldStep() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        for event: TutorialEvent in [.editEntered, .editSaved, .simpleSquareDone] { coach.handle(event) }
        coach.next()
        coach.handle(.countingSheetOpened)
        XCTAssertEqual(coach.session?.step, 5, "the chips")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, 4, "tap Read again")
        coach.handle(.countingSheetOpened)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.session?.step, 6, "the Undo strip (read-only)")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, 7, "nothing left to close: hold Tidy desk")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, 7, "ignored elsewhere")
    }
}
