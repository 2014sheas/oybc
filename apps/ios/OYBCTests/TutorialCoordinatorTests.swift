import XCTest
import GRDB
@testable import OYBC

/// The Getting Started step machine over the facsimile model: each lesson's
/// state advances only on its wired control's event, a step is never skipped,
/// read-only steps take Next alone, leaving saves the step, resuming rebuilds
/// the state the step implies, lesson 1 writes its two real tasks and
/// completion lands in the synced preferences.
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

    /// A coordinator over a fresh test database holding the user row.
    private func makeCoordinator(progress: TutorialProgress = .empty) throws -> (TutorialCoordinator, AppDatabase) {
        let real = try AppDatabase.makeTestInstance()
        try real.saveUser(makeUser())
        for lesson in TutorialLessonID.middleRow { TutorialTypedCache(userId: userId).clear(lesson) }
        return (TutorialCoordinator(userId: userId, database: real, progress: progress), real)
    }

    private func savedProgress(_ db: AppDatabase) throws -> TutorialProgress {
        try XCTUnwrap(db.fetchUser(id: userId)).decodedPreferences.tutorialProgress
    }

    private func ringed(_ coach: TutorialCoordinator) -> [TutorialControlID] {
        (coach.session?.spots ?? []).filter(\.ringed).map(\.id)
    }

    private func open(_ coach: TutorialCoordinator) -> [TutorialControlID] {
        (coach.session?.spots ?? []).filter { !$0.ringed }.map(\.id)
    }

    // MARK: - Lesson 1 · Create a task

    /// Plays lesson 1 through its two writes.
    private func playCreateTask(_ coach: TutorialCoordinator, quick: String = "Stretch 5 min") {
        coach.perform(.plusTapped)
        coach.perform(.typed(.quickAdd, quick))
        coach.perform(.quickAddSubmitted)
        coach.perform(.specialTapped)
        coach.perform(.typed(.verb, "Read"))
        coach.perform(.fieldSubmitted(.verb))
        coach.perform(.typed(.goal, "20"))
        coach.perform(.fieldSubmitted(.goal))
        coach.perform(.typed(.unit, "pages"))
        coach.perform(.fieldSubmitted(.unit))
        coach.perform(.addToLibraryTapped)
    }

    func test_createTask_wiresOneControlPerStepAndWritesTwoRealTasks() throws {
        let (coach, db) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertEqual(ringed(coach), [.tasksPlus])

        coach.perform(.plusTapped)
        XCTAssertEqual(coach.session?.step, 1)
        XCTAssertEqual(ringed(coach), [.quickAddRow])

        coach.perform(.quickAddSubmitted)
        XCTAssertEqual(coach.session?.step, 1, "an empty quick add writes nothing and stays")
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 0)

        coach.perform(.typed(.quickAdd, "  Stretch 5 min "))
        coach.perform(.quickAddSubmitted)
        XCTAssertEqual(coach.session?.step, 2)
        let afterQuick = try db.fetchTasks(userId: userId)
        XCTAssertEqual(afterQuick.map(\.title), ["Stretch 5 min"], "the Simple task is written at once, trimmed")
        XCTAssertEqual(afterQuick.first?.type, .normal)
        guard case .createTask(let s) = coach.session?.state else { return XCTFail("lesson 1 state") }
        XCTAssertEqual(s.addedTitle, "Stretch 5 min")
        XCTAssertEqual(s.quickText, "", "the field clears after the add")

        coach.perform(.specialTapped)
        XCTAssertEqual(ringed(coach), [.verbField])
        coach.perform(.fieldSubmitted(.verb))
        XCTAssertEqual(coach.session?.step, 3, "Return on an empty verb stays")
        coach.perform(.typed(.verb, "Read"))
        coach.perform(.fieldSubmitted(.verb))
        XCTAssertEqual(ringed(coach), [.goalField])
        XCTAssertEqual(open(coach), [.verbField], "the verb stays editable while the goal is lit")

        coach.perform(.typed(.goal, "x"))
        coach.perform(.fieldSubmitted(.goal))
        XCTAssertEqual(coach.session?.step, 4, "a non-number goal stays")
        coach.perform(.typed(.goal, "20"))
        coach.perform(.fieldSubmitted(.goal))
        XCTAssertEqual(ringed(coach), [.unitField])
        XCTAssertEqual(Set(open(coach)), [.verbField, .goalField])

        coach.perform(.typed(.unit, "pages"))
        if case .createTask(let s2) = coach.session?.state {
            XCTAssertEqual(s2.derivedTitle, "Read 20 pages", "the title fills itself in")
        }
        coach.perform(.fieldSubmitted(.unit))
        XCTAssertEqual(ringed(coach), [.addToLibrary])

        coach.perform(.addToLibraryTapped)
        XCTAssertEqual(coach.session?.phase, .complete)
        let all = try db.fetchTasks(userId: userId).sorted { $0.title < $1.title }
        XCTAssertEqual(all.map(\.title), ["Read 20 pages", "Stretch 5 min"])
        let counting = try XCTUnwrap(all.first { $0.type == .counting })
        XCTAssertEqual(counting.action, "Read")
        XCTAssertEqual(counting.unit, "pages")
        XCTAssertEqual(counting.maxCount, 20)
        XCTAssertEqual(try savedProgress(db).state(of: .createTask), .done)
        XCTAssertEqual(try db.read { try SyncQueueItem.fetchCount($0) }, 2 + 1, "two task creates + the preferences update are enqueued")
    }

    func test_createTask_outOfOrderEventsAreIgnored() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.createTask)
        coach.perform(.specialTapped)
        coach.perform(.addToLibraryTapped)
        coach.perform(.fieldSubmitted(.unit))
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 0)
    }

    func test_createTask_completeCardNamesTheTwoTasks() throws {
        let (coach, _) = try makeCoordinator()
        coach.start(.createTask)
        playCreateTask(coach, quick: "Floss")
        guard case .createTask(let s) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s.addedTitle, "Floss")
        XCTAssertEqual(s.countingTitle, "Read 20 pages")
    }

    // MARK: - Lesson 2 · Create a board

    func test_createBoard_onePathThroughTheWizard() throws {
        let (coach, db) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(ringed(coach), [.oneOffCard])

        coach.perform(.oneOffTapped)
        XCTAssertEqual(ringed(coach), [.timeframeWeekly])
        coach.perform(.setupNextTapped)
        XCTAssertEqual(coach.session?.step, 1, "Next means nothing before Weekly")
        coach.perform(.weeklyTapped)
        XCTAssertEqual(ringed(coach), [.sizeCard3])

        coach.perform(.setupNextTapped)
        XCTAssertEqual(coach.session?.step, 2, "Next is not wired until 3×3 is picked")
        coach.perform(.size3Tapped)
        XCTAssertEqual(coach.session?.step, 2, "picking the size moves the ring, not the step")
        XCTAssertEqual(ringed(coach), [.setupNext])
        XCTAssertEqual(open(coach), [.sizeCard3], "the size stays editable while Next is lit")
        coach.perform(.setupNextTapped)
        XCTAssertEqual(coach.session?.step, 3)
        XCTAssertEqual(ringed(coach), [.addFromPool])

        coach.perform(.addFromPoolTapped)
        XCTAssertEqual(ringed(coach), [.poolRow("Fitness")])
        coach.perform(.poolToggled("Reading"))
        coach.perform(.sourcesDoneTapped)
        XCTAssertEqual(coach.session?.step, 4, "a locked pool and an early Done do nothing")
        coach.perform(.poolToggled("Fitness"))
        XCTAssertEqual(ringed(coach), [.sourcesDone])
        coach.perform(.poolToggled("Fitness"))
        XCTAssertEqual(ringed(coach), [.poolRow("Fitness")], "tapping Fitness again unchecks it and dims Done")
        coach.perform(.poolToggled("Fitness"))
        coach.perform(.sourcesDoneTapped)
        XCTAssertEqual(coach.session?.step, 5)
        guard case .createBoard(let s5) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s5.poolCount, 8)
        XCTAssertTrue(s5.satisfied)
        XCTAssertFalse(s5.sourceSheetOpen)
        XCTAssertEqual(ringed(coach), [.sourceRow])

        coach.perform(.sourceRowTapped)
        XCTAssertEqual(ringed(coach), [.memberExclude("Bike to work")])
        coach.perform(.memberExcluded("Run 5k"))
        XCTAssertEqual(coach.session?.step, 6, "only Bike to work's ✕ is wired")
        coach.perform(.memberExcluded("Bike to work"))
        guard case .createBoard(let s7) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s7.poolCount, 7)
        XCTAssertFalse(s7.satisfied, "7/8: Next dims")
        XCTAssertFalse(s7.sourceExpanded, "the stage collapses the panel")
        XCTAssertEqual(s7.sourceSubtitle, "8 tasks · 1 excluded")
        XCTAssertEqual(ringed(coach), [.wizardQuickRow])

        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.step, 7, "Next is not wired at 7/8")
        coach.perform(.typed(.wizardQuickAdd, "Drink water"))
        coach.perform(.wizardQuickSubmitted)
        XCTAssertEqual(coach.session?.step, 7)
        XCTAssertEqual(ringed(coach), [.tasksNext], "8/8: the ring moves to Next")
        XCTAssertEqual(coach.session?.text, "Eight of eight. Tap Next.")
        coach.perform(.wizardQuickSubmitted)
        guard case .createBoard(let s8) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s8.poolCount, 8, "one hand-added task only")
        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.step, 8)
        XCTAssertEqual(ringed(coach), [.activate])

        coach.perform(.activateTapped)
        XCTAssertEqual(coach.session?.phase, .complete)
        XCTAssertEqual(try savedProgress(db).state(of: .createBoard), .done)
        XCTAssertEqual(try db.fetchBoards(userId: userId).count, 0, "nothing was saved to the boards")
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 0, "the hand-added task is part of the fixture")
    }

    func test_createBoard_previewPutsTheHandAddedTaskInTheExcludedSlot() {
        let cells = TutorialCreateBoardFixture.previewCells(handAdded: "Drink water")
        XCTAssertEqual(cells.count, 9)
        XCTAssertNil(cells[4], "free centre")
        XCTAssertEqual(cells.compactMap { $0?.title }, ["Run 5k", "Stretch 10 min", "Walk 10k steps", "Yoga", "Push-ups", "Drink water", "Plank 2 min", "Lift weights"])
        XCTAssertFalse(cells.compactMap { $0?.title }.contains("Bike to work"))
    }

    // MARK: - Lesson 3 · Complete a board

    private typealias L3 = TutorialCompleteBoardState.Step

    private func l3(_ coach: TutorialCoordinator) -> TutorialCompleteBoardState? {
        if case .completeBoard(let s) = coach.session?.state { return s }
        return nil
    }

    /// Lesson 3 up to the hold step.
    private func reachHold(_ coach: TutorialCoordinator) {
        coach.perform(.editTapped)
        coach.perform(.editSquareTapped(TutorialSampleWeek.Slot.journal))
        coach.perform(.replaceRowTapped(TutorialSampleWeek.replacement))
        coach.perform(.saveTapped)
        coach.perform(.squareTapped(TutorialSampleWeek.Slot.stretch))
        coach.next()
        coach.perform(.squareTapped(TutorialSampleWeek.Slot.read))
        coach.perform(.chipTapped(5))
        coach.perform(.chipTapped(5))
        coach.next()
        XCTAssertEqual(coach.session?.step, L3.holdTidy)
    }

    func test_completeBoard_editSwapSaveThenSimpleSquare() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertTrue(coach.start(.completeBoard))
        XCTAssertEqual(l3(coach)?.done, [2, 3, 7])
        XCTAssertEqual(l3(coach)?.completeLines, [], "no line at the start")
        XCTAssertEqual(ringed(coach), [.editButton])

        coach.perform(.squareTapped(TutorialSampleWeek.Slot.stretch))
        XCTAssertEqual(coach.session?.step, 0, "squares are not wired before Edit")
        coach.perform(.editTapped)
        XCTAssertEqual(l3(coach)?.editing, true)
        XCTAssertEqual(ringed(coach), [.editSquare(1)])
        coach.perform(.editSquareTapped(0))
        XCTAssertEqual(coach.session?.step, 1, "only Journal is wired")
        coach.perform(.editSquareTapped(1))
        XCTAssertEqual(l3(coach)?.replaceSheetOpen, true)
        XCTAssertEqual(ringed(coach), [.replaceRow("Meditate 5 min")])
        coach.perform(.replaceRowTapped("Floss"))
        XCTAssertEqual(coach.session?.step, 2, "the other rows are locked")
        coach.perform(.replaceRowTapped("Meditate 5 min"))
        XCTAssertEqual(l3(coach)?.swapped, true)
        XCTAssertEqual(l3(coach)?.replaceSheetOpen, false)
        XCTAssertEqual(l3(coach)?.changeCount, 1)
        XCTAssertEqual(l3(coach)?.title(at: 1), "Meditate 5 min")
        XCTAssertEqual(ringed(coach), [.saveChanges])
        coach.perform(.saveTapped)
        XCTAssertEqual(l3(coach)?.editing, false)
        XCTAssertEqual(ringed(coach), [.square(0)])

        coach.perform(.squareTapped(TutorialSampleWeek.Slot.tidy))
        XCTAssertEqual(coach.session?.step, L3.tapStretch, "only Stretch is wired")
        coach.perform(.squareTapped(0))
        XCTAssertEqual(l3(coach)?.done.contains(0), true)
        XCTAssertEqual(l3(coach)?.toastVisible, true)
        XCTAssertEqual(l3(coach)?.completeLines, [], "Stretch completes no line")
        XCTAssertEqual(coach.session?.showsNext, true, "the toast step is read-only")
        XCTAssertEqual(ringed(coach), [.undoToast])
        coach.perform(.squareTapped(TutorialSampleWeek.Slot.read))
        XCTAssertEqual(coach.session?.step, L3.toast, "nothing but Next moves a read-only step")
        coach.next()
        XCTAssertEqual(l3(coach)?.toastVisible, false)
        XCTAssertEqual(ringed(coach), [.square(4)])
    }

    func test_completeBoard_chipTwiceThenHoldThenBingoThenFinale() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.completeBoard)
        coach.perform(.editTapped)
        coach.perform(.editSquareTapped(1))
        coach.perform(.replaceRowTapped("Meditate 5 min"))
        coach.perform(.saveTapped)
        coach.perform(.squareTapped(0))
        coach.next()
        coach.perform(.squareTapped(4))
        XCTAssertEqual(l3(coach)?.squareSheetOpen, true)
        XCTAssertEqual(ringed(coach), [.chip(5)])
        coach.perform(.chipTapped(1))
        XCTAssertEqual(l3(coach)?.readCount, 12, "only +5 is wired")
        coach.perform(.chipTapped(5))
        XCTAssertEqual(coach.session?.step, L3.chips, "the first tap stays on the step")
        XCTAssertEqual(l3(coach)?.readCount, 17)
        XCTAssertEqual(l3(coach)?.undoText, "Logged +5 pages · Sample week")
        XCTAssertEqual(l3(coach)?.done.contains(4), false)
        coach.perform(.chipTapped(5))
        XCTAssertEqual(coach.session?.step, L3.undoStrip, "the second tap advances")
        XCTAssertEqual(l3(coach)?.readCount, 22, "past the goal still counts")
        XCTAssertEqual(l3(coach)?.done.contains(4), true)
        XCTAssertEqual(l3(coach)?.completeLines, [], "Read completes no line")
        XCTAssertEqual(ringed(coach), [.undoStrip])
        XCTAssertEqual(coach.session?.showsNext, true)
        coach.next()
        XCTAssertEqual(l3(coach)?.squareSheetOpen, false)
        XCTAssertEqual(ringed(coach), [.square(5)])

        coach.perform(.squareTapped(5))
        XCTAssertEqual(coach.session?.step, L3.holdTidy, "a plain tap on Tidy desk does nothing")
        coach.perform(.squareHeld(5))
        XCTAssertEqual(l3(coach)?.holdMenuOpen, true)
        XCTAssertEqual(ringed(coach), [.markDone])
        coach.perform(.markDoneTapped)
        XCTAssertEqual(l3(coach)?.done.contains(5), true)
        XCTAssertEqual(l3(coach)?.holdMenuOpen, false)
        XCTAssertEqual(l3(coach)?.moment, .bingo)
        XCTAssertEqual(l3(coach)?.completeLines, [[3, 4, 5]], "the middle row, and only it")
        XCTAssertEqual(coach.session?.step, L3.finale)
        XCTAssertEqual(coach.session?.state.coachHidden, true, "the moment plays whole")
        XCTAssertEqual(coach.session?.spots, [], "nothing is lit under the moment")
        coach.perform(.squareTapped(1))
        XCTAssertEqual(l3(coach)?.done.contains(1), false, "squares are not wired under the moment")

        coach.perform(.momentBackTapped)
        XCTAssertNil(l3(coach)?.moment)
        XCTAssertEqual(coach.session?.phase, .running)
        XCTAssertEqual(Set(ringed(coach)), [.square(1), .square(6), .square(8)], "three left, any order")
        XCTAssertEqual(l3(coach)?.completedCount, 6)

        coach.perform(.squareTapped(8))
        XCTAssertEqual(l3(coach)?.completeLines.count, 3, "Water plants closes the right column and a diagonal: more gold rings…")
        XCTAssertNil(l3(coach)?.moment, "…with no moment")
        XCTAssertEqual(Set(ringed(coach)), [.square(1), .square(6)])
        coach.perform(.squareTapped(6))
        XCTAssertNil(l3(coach)?.moment)
        coach.perform(.squareTapped(1))
        XCTAssertEqual(l3(coach)?.completedCount, 9)
        XCTAssertEqual(l3(coach)?.moment, .greenlog, "the last square plays the Greenlog only")
        XCTAssertEqual(coach.session?.phase, .running, "not done until a Greenlog button")
        XCTAssertEqual(try savedProgress(db).state(of: .completeBoard), .inProgress(step: L3.finale))

        coach.perform(.momentBackTapped)
        XCTAssertEqual(coach.session?.phase, .complete)
        XCTAssertEqual(coach.session?.exit, .board, "Back to board shows the complete card")
        XCTAssertEqual(try savedProgress(db).state(of: .completeBoard), .done)
        XCTAssertEqual(try db.fetchBoards(userId: userId).count, 0, "no writes at any point")
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 0)
    }

    func test_completeBoard_greenlogStartNewBoardExitsToCreate() throws {
        let (coach, _) = try makeCoordinator()
        coach.start(.completeBoard)
        reachHold(coach)
        coach.perform(.squareHeld(5))
        coach.perform(.markDoneTapped)
        coach.perform(.momentBackTapped)
        for slot in [1, 6, 8] { coach.perform(.squareTapped(slot)) }
        XCTAssertEqual(l3(coach)?.moment, .greenlog)
        coach.perform(.momentNewBoardTapped)
        XCTAssertEqual(coach.session?.phase, .complete)
        XCTAssertEqual(coach.isClosing, true, "the stage closes straight away")
        XCTAssertEqual(coach.justCompleted?.lesson, .completeBoard)
        XCTAssertEqual(coach.justCompleted?.exit, .create)
    }

    func test_completeBoard_fixtureClosesNoLineBeforeTheHold() {
        var done = TutorialSampleWeek.initiallyDone
        XCTAssertEqual(TutorialSampleWeek.completeLines(done), [])
        done.insert(TutorialSampleWeek.Slot.stretch)
        XCTAssertEqual(TutorialSampleWeek.completeLines(done), [])
        done.insert(TutorialSampleWeek.Slot.read)
        XCTAssertEqual(TutorialSampleWeek.completeLines(done), [])
        done.insert(TutorialSampleWeek.Slot.tidy)
        XCTAssertEqual(TutorialSampleWeek.completeLines(done), [[3, 4, 5]])
    }

    // MARK: - Leaving and resuming

    func test_leave_savesTheStepAndResumeRebuildsTheImpliedState() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.createBoard)
        coach.perform(.oneOffTapped)
        coach.perform(.weeklyTapped)
        coach.perform(.size3Tapped)
        coach.perform(.setupNextTapped)
        coach.perform(.addFromPoolTapped)
        coach.perform(.poolToggled("Fitness"))
        coach.perform(.sourcesDoneTapped)
        coach.perform(.sourceRowTapped)
        coach.perform(.memberExcluded("Bike to work"))
        coach.perform(.typed(.wizardQuickAdd, "Drink water"))
        coach.perform(.wizardQuickSubmitted)
        XCTAssertEqual(coach.session?.step, 7)

        coach.requestLeave()
        XCTAssertEqual(coach.session?.phase, .confirmingLeave)
        coach.keepGoing()
        XCTAssertEqual(coach.session?.phase, .running)
        coach.requestLeave()
        coach.leave()
        XCTAssertTrue(coach.isClosing)
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertEqual(try savedProgress(db).state(of: .createBoard), .inProgress(step: 7))

        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.step, 7)
        XCTAssertEqual(coach.session?.resumed, true)
        guard case .createBoard(let s) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s.screen, .tasks)
        XCTAssertTrue(s.poolAdded)
        XCTAssertTrue(s.excluded)
        XCTAssertFalse(s.sourceExpanded)
        XCTAssertEqual(s.handAddedTitle, "Drink water", "what was typed comes back")
        XCTAssertEqual(ringed(coach), [.tasksNext])
        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.resumed, false, "the RESUMED tag shows on the first mark only")
    }

    func test_resume_lesson1_rebuildsTheFieldsWithWhatWasTyped() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.createTask)
        coach.perform(.plusTapped)
        coach.perform(.typed(.quickAdd, "Floss"))
        coach.perform(.quickAddSubmitted)
        coach.perform(.specialTapped)
        coach.perform(.typed(.verb, "Walk"))
        coach.perform(.fieldSubmitted(.verb))
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(try savedProgress(db).state(of: .createTask), .inProgress(step: 4))

        coach.start(.createTask)
        guard case .createTask(let s) = coach.session?.state else { return XCTFail() }
        XCTAssertTrue(s.sheetOpen)
        XCTAssertTrue(s.panelOpen)
        XCTAssertEqual(s.addedTitle, "Floss", "the Added row reflects the real write")
        XCTAssertEqual(s.verb, "Walk")
        XCTAssertEqual(s.goal, "")
        XCTAssertEqual(ringed(coach), [.goalField])
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 1, "Floss stays in the library")
    }

    func test_implied_lesson3_atEveryStep() {
        let L = TutorialCompleteBoardState.Step.self
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.pickReplacement).replaceSheetOpen, true)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.save).changeCount, 1)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.tapStretch).editing, false)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.toast).toastVisible, true)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.chips).readCount, 12)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.undoStrip).readCount, 22)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.undoStrip).undoText, "Logged +5 pages · Sample week")
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.holdTidy).done, [0, 2, 3, 4, 7])
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L.markDone).holdMenuOpen, true)
        let finale = TutorialCompleteBoardState.implied(step: L.finale)
        XCTAssertEqual(finale.done, [0, 2, 3, 4, 5, 7])
        XCTAssertEqual(finale.completeLines, [[3, 4, 5]])
        XCTAssertNil(finale.moment)
        XCTAssertEqual(Set(finale.spots(step: L.finale).map(\.id)), [.square(1), .square(6), .square(8)])
    }

    func test_replayOfADoneLessonStartsAtStepOneAndKeepsItDone() throws {
        var progress = TutorialProgress.empty
        progress.set(.createBoard, .done)
        let (coach, db) = try makeCoordinator(progress: progress)
        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.step, 0)
        XCTAssertEqual(coach.session?.resumed, false)
        coach.perform(.oneOffTapped)
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(coach.progress.state(of: .createBoard), .done, "leaving a replay never demotes a finished lesson")
        XCTAssertEqual(try savedProgress(db), .empty, "and writes nothing (the seeded row never held this progress)")
    }

    func test_start_refusesProSquaresAndASecondLesson() throws {
        let (coach, _) = try makeCoordinator()
        XCTAssertFalse(coach.start(.multiStep))
        XCTAssertTrue(coach.start(.createTask))
        XCTAssertFalse(coach.start(.createBoard))
    }

    func test_eventsAfterCompletionOrWhileClosingAreIgnored() throws {
        let (coach, _) = try makeCoordinator()
        coach.start(.createBoard)
        coach.perform(.oneOffTapped)
        coach.leave()
        coach.perform(.weeklyTapped)
        XCTAssertEqual(coach.session?.step, 1, "closing: no more events")
    }

    func test_finishCompletedLesson_reportsTheExit() throws {
        let (coach, _) = try makeCoordinator()
        coach.start(.createTask)
        playCreateTask(coach)
        XCTAssertEqual(coach.session?.phase, .complete)
        coach.finishCompletedLesson(exit: .tasks)
        XCTAssertEqual(coach.justCompleted?.lesson, .createTask)
        XCTAssertEqual(coach.justCompleted?.exit, .tasks)
        XCTAssertTrue(coach.isClosing)
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        coach.consumeJustCompleted()
        XCTAssertNil(coach.justCompleted)
    }

    func test_dismissCard_onlyOnceTheMiddleRowIsDone() throws {
        let (coach, db) = try makeCoordinator()
        coach.dismissCard()
        XCTAssertFalse(coach.progress.cardDismissed)
        var progress = TutorialProgress.empty
        for id in TutorialLessonID.middleRow { progress.set(id, .done) }
        let (coach2, db2) = try makeCoordinator(progress: progress)
        coach2.dismissCard()
        XCTAssertTrue(coach2.progress.cardDismissed)
        XCTAssertTrue(try savedProgress(db2).cardDismissed)
        _ = db
    }

    func test_reset_clearsEverything() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .done)
        let (coach, db) = try makeCoordinator(progress: progress)
        coach.start(.createBoard)
        coach.reset()
        XCTAssertNil(coach.session)
        XCTAssertEqual(coach.progress, .empty)
        XCTAssertEqual(try savedProgress(db), .empty)
    }

    func test_typedCache_isScopedToTheUserAndInertWithoutOne() {
        let suite = UserDefaults(suiteName: "tutorial-typed-cache-test")!
        suite.removePersistentDomain(forName: "tutorial-typed-cache-test")
        var a = TutorialTypedCache(userId: "a"); a.defaults = suite
        var b = TutorialTypedCache(userId: "b"); b.defaults = suite
        var none = TutorialTypedCache(userId: nil); none.defaults = suite
        a.save(.createTask, ["verb": "Walk"])
        XCTAssertEqual(a.load(.createTask), ["verb": "Walk"])
        XCTAssertEqual(b.load(.createTask), [:], "another user never sees it")
        none.save(.createTask, ["verb": "X"])
        XCTAssertEqual(none.load(.createTask), [:], "a preview coordinator has no cache")
        a.clear(.createTask)
        XCTAssertEqual(a.load(.createTask), [:])
    }

    func test_previewCoordinator_runsWithoutADatabase() {
        let coach = TutorialCoordinator.preview()
        coach.start(.createTask)
        playCreateTask(coach)
        XCTAssertEqual(coach.session?.phase, .complete, "a preview coordinator skips the writes and still completes")
        XCTAssertEqual(coach.progress.state(of: .createTask), .done)
    }

    // MARK: - Catalog

    func test_catalog_stepCountsAndBarLabels() {
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).steps.count, 7)
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).steps.count, 9)
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).steps.count, 12)
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).barLabel, "Lesson 1 · Create a task")
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).barLabel, "Lesson 3 · Complete a board")
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).steps.filter { $0.advance == .next }.count, 2, "two read-only steps")
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).completeSecondary, .tasks)
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).completeSecondary, .create)
        XCTAssertNil(TutorialCatalog.info(for: .completeBoard).completeSecondary)
    }
}
