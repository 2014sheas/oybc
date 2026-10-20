import XCTest
import GRDB
@testable import OYBC

/// The Getting Started step machine: each free lesson's script advances only on
/// its real control's event, holds on the step's done line until Next (Next
/// alone on read-only steps), never skips a step, leaving saves the step,
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

    /// Does the step's action and, when the lesson holds on its done line,
    /// taps Next — what the person does at every action step.
    private func act(_ coach: TutorialCoordinator, _ event: TutorialEvent) {
        coach.handle(event)
        if coach.session?.awaitingNext == true { coach.next() }
    }

    /// Lesson 3 up to the Read square (step 5): Edit, swap, Save, Stretch, the toast's Next.
    private func reachRead(_ coach: TutorialCoordinator) {
        for event: TutorialEvent in [.editEntered, .squareSwapped, .editSaved, .simpleSquareDone] { act(coach, event) }
        coach.next()
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.openRead)
    }

    /// Lesson 3 up to the hold step (step 8): Read logged, the strip's Next.
    private func reachHold(_ coach: TutorialCoordinator) {
        reachRead(coach)
        act(coach, .countingSheetOpened)
        act(coach, .countLogged)
        coach.next()
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.holdTidy)
    }

    // MARK: - Scripts

    private static let createTaskScript: [TutorialEvent] = [
        .tasksPlusTapped, .normalTaskCreated, .specialPanelOpened, .countingFieldsFilled, .countingTaskCreated,
    ]
    private static let createBoardScript: [TutorialEvent] = [
        .oneOffBoardStarted, .boardSizePicked, .setupNext, .sourcesSheetOpened, .poolsPicked,
        .sourceRowExpanded, .memberExcluded, .manualTaskAdded, .tasksStepNext,
        .previewShuffled, .previewRearranged, .boardActivated,
    ]

    func test_createTask_advancesOnEachRealControlEventThenNext() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for (index, event) in Self.createTaskScript.enumerated() {
            XCTAssertEqual(coach.session?.step, index)
            coach.handle(event)
            if index < Self.createTaskScript.count - 1 {
                XCTAssertEqual(coach.session?.awaitingNext, true, "step \(index + 1) holds on its done line")
                XCTAssertEqual(coach.session?.step, index, "the step has not moved")
                coach.next()
            }
        }
        XCTAssertEqual(coach.session?.phase, .complete, "the last action completes without a Next")
    }

    func test_createBoard_advancesOnEachRealControlEventThenNext() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.steps.count, 12)
        for (index, event) in Self.createBoardScript.enumerated() {
            XCTAssertEqual(coach.session?.step, index)
            coach.handle(event)
            if index < Self.createBoardScript.count - 1 {
                XCTAssertEqual(coach.session?.awaitingNext, true)
                coach.next()
            }
        }
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    func test_completeBoard_actionStepsHoldAndReadOnlyStepsNeedOnlyNext() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        XCTAssertEqual(coach.session?.steps.count, 10)
        act(coach, .editEntered)                                    // 1 Edit
        act(coach, .squareSwapped)                                  // 2 Journal → Replace task
        act(coach, .editSaved)                                      // 3 Save
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.tapStretch)
        coach.handle(.simpleSquareDone)                             // 4 Stretch
        XCTAssertEqual(coach.session?.awaitingNext, false, "the next step is read-only: no hold")
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.undoToast)
        XCTAssertTrue(coach.currentStepIsReadOnly, "the Undo toast step is read-only")
        coach.next()                                                // 5 Next
        act(coach, .countingSheetOpened)                            // 6 Read
        coach.handle(.countLogged)                                  // 7 chip
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.undoStrip)
        XCTAssertTrue(coach.currentStepIsReadOnly)
        coach.next()                                                // 8 Next closes the sheet
        XCTAssertEqual(coach.session?.currentStep?.closesSquareSheet, true)
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.holdTidy)
        coach.handle(.bingoMomentClosed)                            // 9 Tidy desk → Bingo moment closes
        XCTAssertEqual(coach.session?.awaitingNext, true)
        XCTAssertEqual(coach.currentText, "Bingo: the middle row is done.")
        coach.next()
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.finale)
        XCTAssertEqual(coach.session?.phase, .running)
        coach.handle(.greenlogMomentClosed)                         // 10 Greenlog closes
        XCTAssertEqual(coach.session?.phase, .complete)
    }

    // MARK: - The hold after an action

    func test_anActionHoldsOnItsDoneLineUntilNext() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(coach.session?.awaitingNext, true)
        XCTAssertEqual(coach.currentText, "The new task sheet is open.")
        XCTAssertTrue(coach.showsNext)
        XCTAssertEqual(coach.session?.litAnchors, [], "every hole is closed")
        XCTAssertEqual(coach.session?.screenStep?.onSheet, true, "the next step's sheet owns the done card")
        coach.handle(.normalTaskCreated)
        XCTAssertEqual(coach.session?.step, 0, "nothing moves the lesson but Next")
        coach.next()
        XCTAssertEqual(coach.session?.step, 1)
        XCTAssertEqual(coach.session?.awaitingNext, false)
        XCTAssertFalse(coach.showsNext)
        XCTAssertEqual(coach.currentText, "Type a task, then tap Add.")
    }

    func test_wrongEventsAndNextOnActionStepsAreIgnored() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.handle(.normalTaskCreated)      // not the step's event
        coach.next()                          // action steps have no Next before their action
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(coach.session?.awaitingNext, false)
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.awaitingNext, true)
    }

    func test_eventsAreIgnoredWhileTheLeaveSheetIsUp() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        coach.requestLeave()
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.awaitingNext, false)
        coach.keepGoing()
        coach.handle(.tasksPlusTapped)
        XCTAssertEqual(coach.session?.awaitingNext, true)
    }

    /// A step is never skipped: a moment closing means nothing unless the
    /// current step waits for exactly that moment.
    func test_aMomentClosingOnAnotherStepNeverSkipsAStep() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        coach.handle(.bingoMomentClosed)
        XCTAssertEqual(coach.session?.step, 0)
        reachHold(coach)
        coach.handle(.greenlogMomentClosed)
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.holdTidy, "the Greenlog is the finale's event, not the hold step's")
        XCTAssertEqual(coach.session?.phase, .running)
    }

    func test_momentOpenHidesTheLayerUntilItCloses() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        coach.setMomentOpen(true)
        XCTAssertEqual(coach.session?.momentOpen, true)
        coach.handle(.bingoMomentClosed)       // not this step's event, but it still un-hides
        XCTAssertEqual(coach.session?.momentOpen, false)
    }

    // MARK: - What the squares accept

    func test_squaresAcceptOnlyTheStepsGesture() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertEqual(coach.signals.squareInteraction, .free, "no lesson: as shipped")
        XCTAssertTrue(coach.start(.completeBoard))
        XCTAssertEqual(coach.signals.squareInteraction, .none, "Edit: squares are inert")
        coach.handle(.editEntered)
        XCTAssertEqual(coach.signals.squareInteraction, .none, "waiting for Next: inert")
        coach.next()
        act(coach, .squareSwapped)
        act(coach, .editSaved)
        XCTAssertEqual(coach.signals.squareInteraction, .tap, "Stretch: tap only")
        coach.handle(.simpleSquareDone)
        coach.next()
        XCTAssertEqual(coach.signals.squareInteraction, .tap, "Read: tap only")
        act(coach, .countingSheetOpened)
        XCTAssertEqual(coach.signals.squareInteraction, .none, "the sheet's steps")
        coach.handle(.countLogged)
        coach.next()
        XCTAssertEqual(coach.signals.squareInteraction, .hold, "Tidy desk: hold only")
        coach.handle(.bingoMomentClosed)
        XCTAssertEqual(coach.signals.squareInteraction, .none)
        coach.next()
        XCTAssertEqual(coach.signals.squareInteraction, .tap, "the finale: tap only")
    }

    // MARK: - Copy that follows what the user did

    func test_loggedSummaryFoldsIntoTheStepCopy() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        reachRead(coach)
        act(coach, .countingSheetOpened)
        coach.reportLog(summary: "22 of 20", finishedSquare: true)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.currentText, "22 of 20. The square is done; Undo stays here.")
    }

    func test_loggedSummaryOnAnUnfinishedSquareDoesNotClaimDone() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        reachRead(coach)
        act(coach, .countingSheetOpened)
        coach.reportLog(summary: "13 of 20", finishedSquare: false)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.currentText, "13 of 20. Undo stays here.")
    }

    func test_poolSummaryFoldsIntoTheDoneLine() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for event in Self.createBoardScript.prefix(4) { act(coach, event) }
        XCTAssertEqual(coach.currentText, "Pick one pool, then tap Done.")
        coach.reportPool(summary: "Home fills eight squares")
        coach.handle(.poolsPicked)
        XCTAssertEqual(coach.currentText, "Home fills eight squares.")
        coach.next()
        XCTAssertEqual(coach.currentText, "Tap the pool to see its tasks.")
    }

    func test_everyLessonThreeStepNamesItsSquare() throws {
        let steps = TutorialCatalog.completeBoardSteps
        XCTAssertEqual(steps[TutorialCatalog.CompleteStep.swapSquare].text, "Tap Journal, then Replace task.")
        XCTAssertEqual(steps[TutorialCatalog.CompleteStep.tapStretch].text, "Tap Stretch to complete it.")
        XCTAssertEqual(steps[TutorialCatalog.CompleteStep.openRead].text, "Tap Read 20 pages to log.")
        XCTAssertEqual(steps[TutorialCatalog.CompleteStep.holdTidy].text, "Hold Tidy desk, then tap Mark done.")
    }

    // MARK: - Completion, leave, resume

    func test_completionIsSavedToTheSyncedPreferences() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        for event in Self.createTaskScript { act(coach, event) }
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
        for event in Self.createTaskScript { act(coach, event) }
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
        for event in Self.createBoardScript.prefix(3) { act(coach, event) }
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

    func test_leavingWhileHoldingOnADoneLineSavesTheNextStep() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        coach.handle(.oneOffBoardStarted)
        XCTAssertEqual(coach.session?.awaitingNext, true)
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 1), "the action happened: the place is the step about to light")
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
        act(coach, .tasksPlusTapped)
        act(coach, .normalTaskCreated)
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
        for event in Self.createBoardScript.prefix(3) { act(coach, event) }
        // An app kill here (no Leave) still keeps "Your place is saved".
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 3))
        XCTAssertEqual(try XCTUnwrap(real.fetchUser(id: userId)).version, v0 + 3, "each action writes its next step once; Next writes nothing")
        coach.leave()
        XCTAssertEqual(try XCTUnwrap(real.fetchUser(id: userId)).version, v0 + 3, "leaving with nothing new writes nothing")
    }

    func test_aStageDismissedWithoutLeaveEndsTheSessionAndSavesThePlace() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        act(coach, .editEntered)
        act(coach, .squareSwapped)
        // e.g. Archive from the Edit BOARD section dismissed the cover.
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertNil(coach.sandboxDatabase)
        XCTAssertEqual(try savedProgress(real).state(of: .completeBoard), .inProgress(step: TutorialCatalog.CompleteStep.saveEdit))
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
        let s = TutorialCatalog.CompleteStep.self
        var facts = try resumeFacts(saved: s.undoToast)     // Stretch done, the toast is gone -> Read
        XCTAssertEqual(facts.step, s.openRead)
        XCTAssertTrue(facts.stretchDone)
        XCTAssertEqual(facts.read, 12)
        facts = try resumeFacts(saved: s.logChip)           // the sheet is closed -> reopen Read
        XCTAssertEqual(facts.step, s.openRead)
        XCTAssertEqual(facts.read, 12)
        facts = try resumeFacts(saved: s.undoStrip)         // Read already 22/20, sheet closed -> hold Tidy desk
        XCTAssertEqual(facts.step, s.holdTidy)
        XCTAssertEqual(facts.read, 22)
        XCTAssertFalse(facts.tidyDone)
        facts = try resumeFacts(saved: s.finale)            // the Bingo already happened
        XCTAssertEqual(facts.step, s.finale)
        XCTAssertTrue(facts.tidyDone)
        facts = try resumeFacts(saved: s.swapSquare)        // the Edit panel is not open
        XCTAssertEqual(facts.step, s.enterEdit)
        XCTAssertFalse(facts.stretchDone)
        facts = try resumeFacts(saved: s.saveEdit)          // the swap is lost with the panel
        XCTAssertEqual(facts.step, s.enterEdit)
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
        reachHold(coach)
        act(coach, .bingoMomentClosed)
        XCTAssertEqual(coach.session?.step, TutorialCatalog.CompleteStep.finale)
        XCTAssertEqual(coach.currentText, "Three left. Tap each to complete it.", "static fallback before the board reports")
        coach.reportIncomplete(slots: [0, 1, 6, 8])
        XCTAssertEqual(coach.session?.litAnchors, [.square(0), .square(1), .square(6), .square(8)], "a square the user undid is lit too")
        XCTAssertEqual(coach.currentText, "Four left. Tap each to complete it.")
        coach.reportIncomplete(slots: [1, 6])
        XCTAssertEqual(coach.currentText, "Two left. Tap each to complete it.")
        coach.reportIncomplete(slots: [6])
        XCTAssertEqual(coach.currentText, "One left. Tap it to complete it.")
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

    // MARK: - A lit sheet closed early steps back

    func test_sourcesSheetClosedWithoutAPoolLightsTheEntryRowAgain() throws {
        let (coach, real) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        for event in Self.createBoardScript.prefix(3) { act(coach, event) }
        coach.handle(.sourcesSheetOpened)
        XCTAssertEqual(coach.session?.awaitingNext, true, "the sheet is up, the done line holds")
        coach.handle(.sourcesSheetClosedEmpty)
        XCTAssertEqual(coach.session?.step, 3, "swiped away before Next: back to Add from a pool or board")
        XCTAssertEqual(coach.session?.awaitingNext, false)
        act(coach, .sourcesSheetOpened)
        XCTAssertEqual(coach.session?.step, 4, "the pool rows")
        coach.handle(.sourcesSheetClosedEmpty)
        XCTAssertEqual(coach.session?.step, 3, "back to Add from a pool or board")
        XCTAssertEqual(try savedProgress(real).state(of: .createBoard), .inProgress(step: 4), "the saved place is never lowered")
        act(coach, .sourcesSheetOpened)
        coach.reportPool(summary: "Fitness fills eight squares")
        act(coach, .poolsPicked)
        XCTAssertEqual(coach.session?.step, 5)
        coach.handle(.sourcesSheetClosedEmpty)
        XCTAssertEqual(coach.session?.step, 5, "means nothing once the pool is in")
    }

    func test_squareSheetSwipedAwayStepsBackToReadOrOnToTheHoldStep() throws {
        let s = TutorialCatalog.CompleteStep.self
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        reachRead(coach)
        coach.handle(.countingSheetOpened)
        XCTAssertEqual(coach.session?.awaitingNext, true)
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, s.openRead, "the sheet went before Next: tap Read again")
        XCTAssertEqual(coach.session?.awaitingNext, false)
        act(coach, .countingSheetOpened)
        XCTAssertEqual(coach.session?.step, s.logChip, "the chips")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, s.openRead, "tap Read again")
        act(coach, .countingSheetOpened)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.session?.step, s.undoStrip, "the Undo strip (read-only)")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, s.holdTidy, "nothing left to close: hold Tidy desk")
        coach.handle(.squareSheetClosed)
        XCTAssertEqual(coach.session?.step, s.holdTidy, "ignored elsewhere")
    }

    func test_undoOnTheStripStepsBackToTheChips() throws {
        let s = TutorialCatalog.CompleteStep.self
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        reachRead(coach)
        act(coach, .countingSheetOpened)
        coach.handle(.countLogged)
        XCTAssertEqual(coach.session?.step, s.undoStrip, "the Undo strip")
        coach.handle(.squareLogUndone)
        XCTAssertEqual(coach.session?.step, s.logChip, "log with a chip again")
        coach.handle(.squareLogUndone)
        XCTAssertEqual(coach.session?.step, s.logChip, "ignored elsewhere")
    }

    // MARK: - Square anchors follow their title

    /// Edit lets the person drag squares around: a `.square` anchor names its
    /// square by seeded slot and resolves to wherever that title sits now.
    func test_squareAnchorsFollowTheTitleTheBoardReports() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        act(coach, .editEntered)
        act(coach, .squareSwapped)
        act(coach, .editSaved)
        XCTAssertEqual(coach.session?.litAnchors, [.square(TutorialCatalog.SampleSlot.stretch)], "the seeded slot before the board reports")
        // Journal was dragged onto Read's slot (and Read onto Journal's).
        var slots: [String: Int] = [:]
        for (index, square) in AppDatabase.tutorialSampleWeekGrid.enumerated() { slots[square.title] = index }
        slots["Journal"] = TutorialCatalog.SampleSlot.read
        slots["Read 20 pages"] = TutorialCatalog.SampleSlot.journal
        coach.reportSlots(byTitle: slots)
        XCTAssertEqual(coach.session?.litAnchors, [.square(TutorialCatalog.SampleSlot.stretch)], "Stretch did not move")
        coach.handle(.simpleSquareDone)
        coach.next()
        XCTAssertEqual(coach.session?.litAnchors, [.square(TutorialCatalog.SampleSlot.journal)], "Read is lit where it sits now")
    }
}
