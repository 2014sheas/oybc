import XCTest
import GRDB
@testable import OYBC

/// The Getting Started step machine over the facsimile model: each lesson's
/// state advances only on its wired control's event, a step is never skipped,
/// read-only steps and tells take Next alone, leaving saves the step, resuming
/// rebuilds the state the step implies, lesson 1 writes its two real tasks and
/// completion lands in the synced preferences.
@MainActor
final class TutorialCoordinatorTests: XCTestCase {

    private let userId = "u1"

    private typealias L1 = TutorialCreateTaskState.Step
    private typealias L2 = TutorialCreateBoardState.Step
    private typealias L3 = TutorialCompleteBoardState.Step

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

    // MARK: - Tells

    func test_tells_lightNothingAndAdvanceOnNextAlone() throws {
        let (coach, _) = try makeCoordinator()
        coach.start(.createTask)
        XCTAssertEqual(coach.session?.step, L1.tellLibrary)
        XCTAssertEqual(coach.session?.title, "Your library")
        XCTAssertEqual(coach.session?.text, "Every task you make is saved here, and boards take their squares from it. One task can sit on many boards.")
        XCTAssertNil(coach.session?.note, "a tell has a title and a body, no note")
        XCTAssertEqual(coach.session?.showsNext, true)
        XCTAssertEqual(coach.session?.spots, [], "nothing is lifted under a tell")
        coach.perform(.plusTapped)
        XCTAssertEqual(coach.session?.step, L1.tellLibrary, "the + is under the scrim during the tell")
        coach.next()
        XCTAssertEqual(coach.session?.step, L1.plus)
        XCTAssertNil(coach.session?.title)
        XCTAssertEqual(coach.session?.text, "Tap + to add a task.")
        XCTAssertEqual(coach.session?.note, "Search and the filters find tasks you already have.")
        XCTAssertEqual(coach.session?.showsNext, false)
        coach.next()
        XCTAssertEqual(coach.session?.step, L1.plus, "Next means nothing on an action step")
    }

    func test_catalog_everyLessonHasThreeTellsPlacedBeforeTheStepTheySetUp() {
        for (lesson, tells) in [(TutorialLessonID.createTask, L1.tells), (.createBoard, L2.tells), (.completeBoard, L3.tells)] {
            let steps = TutorialCatalog.info(for: lesson).steps
            XCTAssertEqual(Set(steps.indices.filter { steps[$0].isTell }), tells, "\(lesson): the state's tell steps are the catalog's")
            XCTAssertEqual(tells.count, 3)
            for i in tells { XCTAssertEqual(steps[i].advance, .next) }
        }
    }

    // MARK: - Lesson 1 · Create a task

    /// Plays lesson 1 through its two writes.
    private func playCreateTask(_ coach: TutorialCoordinator, quick: String = "Stretch 5 min") {
        coach.next()
        coach.perform(.plusTapped)
        coach.next()
        coach.perform(.typed(.quickAdd, quick))
        coach.perform(.quickAddSubmitted)
        coach.perform(.specialTapped)
        coach.next()
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
        coach.next()
        XCTAssertEqual(ringed(coach), [.tasksPlus])

        coach.perform(.plusTapped)
        XCTAssertEqual(coach.session?.step, L1.tellKinds)
        XCTAssertEqual(coach.session?.title, "Two kinds of task")
        guard case .createTask(let s0) = coach.session?.state else { return XCTFail("lesson 1 state") }
        XCTAssertTrue(s0.sheetOpen, "the second tell sits over the open sheet")
        coach.next()
        XCTAssertEqual(coach.session?.step, L1.quickAdd)
        XCTAssertEqual(ringed(coach), [.quickAddRow])

        coach.perform(.quickAddSubmitted)
        XCTAssertEqual(coach.session?.step, L1.quickAdd, "an empty quick add writes nothing and stays")
        XCTAssertEqual(try db.fetchTasks(userId: userId).count, 0)

        coach.perform(.typed(.quickAdd, "  Stretch 5 min "))
        coach.perform(.quickAddSubmitted)
        XCTAssertEqual(coach.session?.step, L1.special)
        let afterQuick = try db.fetchTasks(userId: userId)
        XCTAssertEqual(afterQuick.map(\.title), ["Stretch 5 min"], "the Simple task is written at once, trimmed")
        XCTAssertEqual(afterQuick.first?.type, .normal)
        guard case .createTask(let s) = coach.session?.state else { return XCTFail("lesson 1 state") }
        XCTAssertEqual(s.addedTitle, "Stretch 5 min")
        XCTAssertEqual(s.quickText, "", "the field clears after the add")
        XCTAssertEqual(coach.session?.text, "Tap Counting · Compound · Achievement.")

        coach.perform(.specialTapped)
        XCTAssertEqual(coach.session?.step, L1.tellCounter)
        XCTAssertEqual(coach.session?.title, "Three parts make a counter")
        guard case .createTask(let s1) = coach.session?.state else { return XCTFail() }
        XCTAssertTrue(s1.panelOpen, "the third tell sits over the open panel")
        coach.next()
        XCTAssertEqual(ringed(coach), [.verbField])
        coach.perform(.fieldSubmitted(.verb))
        XCTAssertEqual(coach.session?.step, L1.verb, "Return on an empty verb stays")
        coach.perform(.typed(.verb, "Read"))
        coach.perform(.fieldSubmitted(.verb))
        XCTAssertEqual(ringed(coach), [.goalField])
        XCTAssertEqual(open(coach), [.verbField], "the verb stays editable while the goal is lit")

        coach.perform(.typed(.goal, "x"))
        coach.perform(.fieldSubmitted(.goal))
        XCTAssertEqual(coach.session?.step, L1.goal, "a non-number goal stays")
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

    func test_createTask_resumeOnSpecialTypeShowsTheShortFormWithoutANote() throws {
        var progress = TutorialProgress.empty
        progress.set(.createTask, .inProgress(step: L1.special))
        let (coach, _) = try makeCoordinator(progress: progress)
        TutorialTypedCache(userId: userId).save(.createTask, [TutorialField.quickAdd.rawValue: "Floss"])
        coach.start(.createTask)
        XCTAssertEqual(coach.session?.resumed, true)
        XCTAssertEqual(coach.session?.text, "Tap Special type.")
        XCTAssertNil(coach.session?.note, "the RESUMED mark carries the short form alone")
        coach.perform(.specialTapped)
        XCTAssertEqual(coach.session?.resumed, false)
        XCTAssertEqual(coach.session?.title, "Three parts make a counter")
    }

    // MARK: - Lesson 2 · Create a board

    func test_createBoard_onePathThroughTheWizard() throws {
        let (coach, db) = try makeCoordinator()
        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(ringed(coach), [.oneOffCard])

        coach.perform(.oneOffTapped)
        XCTAssertEqual(coach.session?.step, L2.tellSetup)
        XCTAssertEqual(coach.session?.title, "When and how big")
        guard case .createBoard(let s1) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s1.screen, .setup, "the tell sits over Setup with nothing picked")
        XCTAssertFalse(s1.timeframePicked)
        coach.perform(.weeklyTapped)
        XCTAssertEqual(coach.session?.step, L2.tellSetup, "Weekly is under the scrim during the tell")
        coach.next()
        XCTAssertEqual(ringed(coach), [.timeframeWeekly])
        coach.perform(.setupNextTapped)
        XCTAssertEqual(coach.session?.step, L2.timeframe, "Next means nothing before Weekly")
        coach.perform(.weeklyTapped)

        XCTAssertEqual(coach.session?.step, L2.window)
        XCTAssertEqual(ringed(coach), [.windowChip], "the window chip is lit to read")
        XCTAssertEqual(coach.session?.text, "This board runs the week of Oct 20 – 26.")
        XCTAssertEqual(coach.session?.showsNext, true)
        coach.perform(.size3Tapped)
        XCTAssertEqual(coach.session?.step, L2.window, "the size cards wait for Next")
        coach.next()

        XCTAssertEqual(coach.session?.step, L2.size)
        XCTAssertEqual(ringed(coach), [.sizeCard3])
        coach.perform(.setupNextTapped)
        XCTAssertEqual(coach.session?.step, L2.size, "Next is not wired until 3×3 is picked")
        coach.perform(.size3Tapped)
        XCTAssertEqual(coach.session?.step, L2.setupNext, "picking the size moves on to Next")
        XCTAssertEqual(ringed(coach), [.taskCountLabel, .centerRow, .setupNext], "the count and the centre row lit to read, Next wired")
        XCTAssertEqual(coach.session?.spots.filter(\.primary).map(\.id), [.setupNext], "only Next is the notch's target")
        XCTAssertEqual(coach.session?.text, "Tap Next.")
        coach.perform(.setupNextTapped)

        XCTAssertEqual(coach.session?.step, L2.tellSources)
        XCTAssertEqual(coach.session?.title, "Where squares come from")
        guard case .createBoard(let s6) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s6.screen, .tasks)
        XCTAssertEqual(s6.poolCount, 0)
        coach.next()
        XCTAssertEqual(ringed(coach), [.addFromPool])

        coach.perform(.addFromPoolTapped)
        XCTAssertEqual(ringed(coach), [.poolRow("Fitness")])
        coach.perform(.poolToggled("Reading"))
        coach.perform(.sourcesDoneTapped)
        XCTAssertEqual(coach.session?.step, L2.pickPool, "a locked pool and an early Done do nothing")
        coach.perform(.poolToggled("Fitness"))
        XCTAssertEqual(ringed(coach), [.sourcesDone])
        coach.perform(.poolToggled("Fitness"))
        XCTAssertEqual(ringed(coach), [.poolRow("Fitness")], "tapping Fitness again unchecks it and dims Done")
        coach.perform(.poolToggled("Fitness"))
        coach.perform(.sourcesDoneTapped)

        XCTAssertEqual(coach.session?.step, L2.tellTune)
        XCTAssertEqual(coach.session?.title, "Tune what a pool deals")
        guard case .createBoard(let s9) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s9.poolCount, 8)
        XCTAssertTrue(s9.satisfied)
        XCTAssertFalse(s9.sourceSheetOpen)
        coach.next()
        XCTAssertEqual(ringed(coach), [.sourceRow])

        coach.perform(.sourceRowTapped)
        XCTAssertEqual(ringed(coach), [.memberExclude("Bike to work")])
        coach.perform(.memberExcluded("Run 5k"))
        XCTAssertEqual(coach.session?.step, L2.exclude, "only Bike to work's ✕ is wired")
        coach.perform(.memberExcluded("Bike to work"))
        guard case .createBoard(let s12) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s12.poolCount, 7)
        XCTAssertFalse(s12.satisfied, "7/8: Next dims")
        XCTAssertFalse(s12.sourceExpanded, "the stage collapses the panel")
        XCTAssertEqual(s12.sourceSubtitle, "8 tasks · 1 excluded")
        XCTAssertEqual(ringed(coach), [.wizardQuickRow])
        XCTAssertEqual(coach.session?.text, "Type a task, then tap Add.")

        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.step, L2.handAdd, "Next is not wired at 7/8")
        coach.perform(.typed(.wizardQuickAdd, "Drink water"))
        coach.perform(.wizardQuickSubmitted)
        XCTAssertEqual(coach.session?.step, L2.handAdd)
        XCTAssertEqual(ringed(coach), [.tasksNext], "8/8: the ring moves to Next")
        XCTAssertEqual(coach.session?.text, "Tap Next.")
        XCTAssertEqual(coach.session?.note, "8 of 8. The meter turns green once the board has enough tasks.")
        coach.perform(.wizardQuickSubmitted)
        guard case .createBoard(let s13) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s13.poolCount, 8, "one hand-added task only")
        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.step, L2.activate)
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

    func test_createBoard_windowChipAndCoachLineNameTheSameWeek() {
        XCTAssertEqual(TutorialCreateBoardFixture.windowLabel, "Week of Oct 20 – 26, 2026")
        XCTAssertEqual(TutorialCatalog.createBoardSteps[L2.window].text, TutorialCreateBoardFixture.windowLine)
        XCTAssertFalse(TutorialCreateBoardState.implied(step: L2.timeframe, typed: [:]).timeframePicked, "\"Pick a timeframe\" until the tap")
        XCTAssertTrue(TutorialCreateBoardState.implied(step: L2.window, typed: [:]).timeframePicked)
        XCTAssertFalse(TutorialCreateBoardState.implied(step: L2.size, typed: [:]).sizePicked)
        XCTAssertTrue(TutorialCreateBoardState.implied(step: L2.setupNext, typed: [:]).sizePicked)
        XCTAssertEqual(TutorialCreateBoardState.implied(step: L2.tellSources, typed: [:]).screen, .tasks)
        XCTAssertFalse(TutorialCreateBoardState.implied(step: L2.tellSources, typed: [:]).poolAdded)
        XCTAssertTrue(TutorialCreateBoardState.implied(step: L2.tellTune, typed: [:]).poolAdded)
    }

    // MARK: - Lesson 3 · Complete a board

    private func l3(_ coach: TutorialCoordinator) -> TutorialCompleteBoardState? {
        if case .completeBoard(let s) = coach.session?.state { return s }
        return nil
    }

    /// Lesson 3 up to the hold step.
    private func reachHold(_ coach: TutorialCoordinator) {
        coach.next()
        coach.perform(.editTapped)
        coach.perform(.editSquareTapped(TutorialSampleWeek.Slot.journal))
        coach.perform(.replaceRowTapped(TutorialSampleWeek.replacement))
        coach.perform(.saveTapped)
        coach.next()
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
        XCTAssertEqual(coach.session?.title, "Reading a board")
        XCTAssertEqual(coach.session?.spots, [])
        coach.perform(.editTapped)
        XCTAssertEqual(coach.session?.step, L3.tellReading, "Edit is under the scrim during the tell")
        coach.next()
        XCTAssertEqual(ringed(coach), [.editButton])

        coach.perform(.squareTapped(TutorialSampleWeek.Slot.stretch))
        XCTAssertEqual(coach.session?.step, L3.edit, "squares are not wired before Edit")
        coach.perform(.editTapped)
        XCTAssertEqual(l3(coach)?.editing, true)
        XCTAssertEqual(ringed(coach), [.editSquare(1)])
        coach.perform(.editSquareTapped(0))
        XCTAssertEqual(coach.session?.step, L3.tapJournal, "only Journal is wired")
        coach.perform(.editSquareTapped(1))
        XCTAssertEqual(l3(coach)?.replaceSheetOpen, true)
        XCTAssertEqual(ringed(coach), [.replaceRow("Meditate 5 min")])
        coach.perform(.replaceRowTapped("Floss"))
        XCTAssertEqual(coach.session?.step, L3.pickReplacement, "the other rows are locked")
        coach.perform(.replaceRowTapped("Meditate 5 min"))
        XCTAssertEqual(l3(coach)?.swapped, true)
        XCTAssertEqual(l3(coach)?.replaceSheetOpen, false)
        XCTAssertEqual(l3(coach)?.changeCount, 1)
        XCTAssertEqual(l3(coach)?.title(at: 1), "Meditate 5 min")
        XCTAssertEqual(ringed(coach), [.saveChanges])
        coach.perform(.saveTapped)
        XCTAssertEqual(l3(coach)?.editing, false)

        XCTAssertEqual(coach.session?.step, L3.tellPlay)
        XCTAssertEqual(coach.session?.title, "Three ways to play a square")
        XCTAssertEqual(coach.session?.spots, [])
        coach.next()
        XCTAssertEqual(ringed(coach), [.square(0)])

        coach.perform(.squareTapped(TutorialSampleWeek.Slot.tidy))
        XCTAssertEqual(coach.session?.step, L3.tapStretch, "only Stretch is wired")
        coach.perform(.squareTapped(0))
        XCTAssertEqual(l3(coach)?.done.contains(0), true)
        XCTAssertEqual(l3(coach)?.toastVisible, true)
        XCTAssertEqual(l3(coach)?.completeLines, [], "Stretch completes no line")
        XCTAssertEqual(coach.session?.showsNext, true, "the toast step is read-only")
        XCTAssertEqual(coach.session?.text, "Done. Undo if you did not mean it.")
        XCTAssertEqual(ringed(coach), [.undoToast])
        coach.perform(.squareTapped(TutorialSampleWeek.Slot.read))
        XCTAssertEqual(coach.session?.step, L3.toast, "nothing but Next moves a read-only step")
        coach.next()
        XCTAssertEqual(l3(coach)?.toastVisible, false)
        XCTAssertEqual(ringed(coach), [.square(4)])
    }

    func test_completeBoard_chipTwiceThenHoldThenBingoStepThenFinale() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.completeBoard)
        coach.next()
        coach.perform(.editTapped)
        coach.perform(.editSquareTapped(1))
        coach.perform(.replaceRowTapped("Meditate 5 min"))
        coach.perform(.saveTapped)
        coach.next()
        coach.perform(.squareTapped(0))
        coach.next()
        coach.perform(.squareTapped(4))
        XCTAssertEqual(l3(coach)?.squareSheetOpen, true)
        XCTAssertEqual(ringed(coach), [.chip(5)])
        XCTAssertEqual(coach.session?.text, "Tap +5 twice.")
        coach.perform(.chipTapped(1))
        XCTAssertEqual(l3(coach)?.readCount, 12, "only +5 is wired")
        coach.perform(.chipTapped(5))
        XCTAssertEqual(coach.session?.step, L3.chips, "the first tap stays on the step")
        XCTAssertEqual(l3(coach)?.readCount, 17)
        XCTAssertEqual(l3(coach)?.undoText, "Logged +5 pages · Sample week")
        XCTAssertEqual(l3(coach)?.done.contains(4), false)
        XCTAssertEqual(coach.session?.text, "Tap +5 once more.", "10b: the line moves on with the count")
        XCTAssertEqual(coach.session?.note, "17 of 20. Undo under the chips takes back the last log.")
        coach.perform(.chipTapped(5))
        XCTAssertEqual(coach.session?.step, L3.undoStrip, "the second tap advances")
        XCTAssertEqual(l3(coach)?.readCount, 22, "past the goal still counts")
        XCTAssertEqual(l3(coach)?.done.contains(4), true)
        XCTAssertEqual(l3(coach)?.completeLines, [], "Read completes no line")
        XCTAssertEqual(ringed(coach), [.undoStrip])
        XCTAssertEqual(coach.session?.showsNext, true)
        XCTAssertEqual(coach.session?.text, "22 of 20. The square is done.")
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

        // Step 14: the shipped Bingo moment, with the coach mark alone over it.
        XCTAssertEqual(coach.session?.step, L3.bingoMoment)
        XCTAssertEqual(coach.session?.state.scrimHidden, true, "the moment plays whole: no scrim, no ring")
        XCTAssertEqual(coach.session?.spots, [], "nothing is lit under the moment")
        XCTAssertEqual(coach.session?.text, "Tap Back to board.")
        XCTAssertEqual(coach.session?.note, "The middle row is a Bingo. Share is off in the tutorial.")
        XCTAssertEqual(coach.session?.showsNext, false)
        coach.next()
        XCTAssertEqual(coach.session?.step, L3.bingoMoment, "Next means nothing here; the moment's button is the control")
        coach.perform(.squareTapped(1))
        XCTAssertEqual(l3(coach)?.done.contains(1), false, "squares are not wired under the moment")
        coach.perform(.momentNewBoardTapped)
        XCTAssertEqual(coach.session?.step, L3.bingoMoment, "the Bingo moment has no Start a new board")
        XCTAssertEqual(try savedProgress(db).state(of: .completeBoard), .inProgress(step: L3.bingoMoment))

        coach.perform(.momentBackTapped)
        XCTAssertNil(l3(coach)?.moment)
        XCTAssertEqual(coach.session?.step, L3.tellLines, "Back to board moves on to the tell")
        XCTAssertEqual(coach.session?.title, "Lines and the Greenlog")
        XCTAssertEqual(coach.session?.state.scrimHidden, false)
        XCTAssertEqual(l3(coach)?.ringedSlots, [3, 4, 5], "the middle row stays ringed gold under the tell")
        coach.next()

        XCTAssertEqual(coach.session?.step, L3.finale)
        XCTAssertEqual(coach.session?.phase, .running)
        XCTAssertEqual(Set(ringed(coach)), [.square(1), .square(6), .square(8)], "three left, any order")
        XCTAssertEqual(coach.session?.text, "Three left. Tap any of them.")
        XCTAssertEqual(l3(coach)?.completedCount, 6)

        coach.perform(.squareTapped(1))
        // Stretch and Call mom were done, so Meditate closes the top row as well as
        // the middle column (the canvas's 16b rings the column alone; the note
        // follows the fixture).
        XCTAssertEqual(l3(coach)?.completeLines.count, 3, "Meditate closes the top row and the middle column…")
        XCTAssertNil(l3(coach)?.moment, "…with no moment")
        XCTAssertEqual(coach.session?.text, "Two left.", "16b")
        XCTAssertEqual(coach.session?.note, "That made two more lines, the top row and the middle column. They ring gold; the moment only plays once per board here.")
        XCTAssertEqual(Set(ringed(coach)), [.square(6), .square(8)])
        coach.perform(.squareTapped(8))
        XCTAssertEqual(l3(coach)?.completeLines.count, 5, "Water plants closes the right column and a diagonal")
        XCTAssertNil(l3(coach)?.moment)
        XCTAssertEqual(coach.session?.text, "One left.")
        XCTAssertEqual(coach.session?.note, "That made two more lines, the right column and a diagonal. They ring gold; the moment only plays once per board here.")
        coach.perform(.squareTapped(6))
        XCTAssertEqual(l3(coach)?.completedCount, 9)
        XCTAssertEqual(l3(coach)?.moment, .greenlog, "the last square plays the Greenlog only")
        XCTAssertEqual(coach.session?.phase, .running, "not done until a Greenlog button")
        XCTAssertEqual(coach.session?.text, "Tap Start a new board, or Back to board.", "16c")
        XCTAssertEqual(coach.session?.note, "Every square done. Share is off in the tutorial.")
        XCTAssertEqual(coach.session?.state.scrimHidden, true)
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
        coach.next()
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

    func test_completeBoard_finaleNoteNamesWhateverLineTheTapClosed() {
        var one = TutorialCompleteBoardState.implied(step: L3.finale)
        XCTAssertEqual(one.apply(.squareTapped(TutorialSampleWeek.Slot.noSugar), step: L3.finale), .stayed)
        XCTAssertEqual(one.stepOverride(step: L3.finale)?.note, "That made two more lines, the left column and a diagonal. They ring gold; the moment only plays once per board here.")
        // Every first tap on this fixture closes two lines; the singular form is for a board that closes one.
        XCTAssertEqual(
            TutorialCatalog.completeBoardFinaleStep(remaining: 2, newLines: ["the middle column"], lineCount: 2).note,
            "That made a second line, the middle column. It rings gold; the moment only plays once per board here."
        )
        XCTAssertEqual(TutorialCatalog.completeBoardFinaleStep(remaining: 1, newLines: [], lineCount: 3).text, "One left.")
        // Any order: the first tap always closes at least one line on this fixture.
        for first in [1, 6, 8] {
            var s = TutorialCompleteBoardState.implied(step: L3.finale)
            XCTAssertEqual(s.apply(.squareTapped(first), step: L3.finale), .stayed)
            let shown = s.stepOverride(step: L3.finale)
            XCTAssertEqual(shown?.text, "Two left.")
            XCTAssertTrue(shown?.note?.hasPrefix("That made ") == true, "\(first): \(shown?.note ?? "")")
        }
        XCTAssertEqual(TutorialSampleWeek.lineName([1, 4, 7]), "the middle column")
        XCTAssertEqual(TutorialSampleWeek.lineName([0, 3, 6]), "the left column")
        XCTAssertEqual(TutorialSampleWeek.lineName([6, 7, 8]), "the bottom row")
        XCTAssertEqual(TutorialSampleWeek.lineName([2, 4, 6]), "a diagonal")
    }

    // MARK: - Leaving and resuming

    func test_leave_savesTheStepAndResumeRebuildsTheImpliedState() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.createBoard)
        coach.perform(.oneOffTapped)
        coach.next()
        coach.perform(.weeklyTapped)
        coach.next()
        coach.perform(.size3Tapped)
        coach.perform(.setupNextTapped)
        coach.next()
        coach.perform(.addFromPoolTapped)
        coach.perform(.poolToggled("Fitness"))
        coach.perform(.sourcesDoneTapped)
        coach.next()
        coach.perform(.sourceRowTapped)
        coach.perform(.memberExcluded("Bike to work"))
        coach.perform(.typed(.wizardQuickAdd, "Drink water"))
        coach.perform(.wizardQuickSubmitted)
        XCTAssertEqual(coach.session?.step, L2.handAdd)

        coach.requestLeave()
        XCTAssertEqual(coach.session?.phase, .confirmingLeave)
        coach.keepGoing()
        XCTAssertEqual(coach.session?.phase, .running)
        coach.requestLeave()
        coach.leave()
        XCTAssertTrue(coach.isClosing)
        coach.stageDidDismiss()
        XCTAssertNil(coach.session)
        XCTAssertEqual(try savedProgress(db).state(of: .createBoard), .inProgress(step: L2.handAdd))

        XCTAssertTrue(coach.start(.createBoard))
        XCTAssertEqual(coach.session?.step, L2.handAdd)
        XCTAssertEqual(coach.session?.resumed, true)
        guard case .createBoard(let s) = coach.session?.state else { return XCTFail() }
        XCTAssertEqual(s.screen, .tasks)
        XCTAssertTrue(s.poolAdded)
        XCTAssertTrue(s.excluded)
        XCTAssertFalse(s.sourceExpanded)
        XCTAssertEqual(s.handAddedTitle, "Drink water", "what was typed comes back")
        XCTAssertEqual(ringed(coach), [.tasksNext])
        XCTAssertEqual(coach.session?.text, "Tap Next.")
        coach.perform(.tasksNextTapped)
        XCTAssertEqual(coach.session?.resumed, false, "the RESUMED tag shows on the first mark only")
    }

    func test_resume_lesson1_rebuildsTheFieldsWithWhatWasTyped() throws {
        let (coach, db) = try makeCoordinator()
        coach.start(.createTask)
        coach.next()
        coach.perform(.plusTapped)
        coach.next()
        coach.perform(.typed(.quickAdd, "Floss"))
        coach.perform(.quickAddSubmitted)
        coach.perform(.specialTapped)
        coach.next()
        coach.perform(.typed(.verb, "Walk"))
        coach.perform(.fieldSubmitted(.verb))
        coach.leave()
        coach.stageDidDismiss()
        XCTAssertEqual(try savedProgress(db).state(of: .createTask), .inProgress(step: L1.goal))

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

    func test_resume_onTheBingoStepReplaysTheMoment() throws {
        var progress = TutorialProgress.empty
        progress.set(.completeBoard, .inProgress(step: L3.bingoMoment))
        let (coach, _) = try makeCoordinator(progress: progress)
        coach.start(.completeBoard)
        XCTAssertEqual(l3(coach)?.moment, .bingo)
        XCTAssertEqual(l3(coach)?.done, [0, 2, 3, 4, 5, 7])
        XCTAssertEqual(coach.session?.text, "Tap Back to board.")
        coach.perform(.momentBackTapped)
        XCTAssertEqual(coach.session?.step, L3.tellLines)
    }

    func test_implied_lesson3_atEveryStep() {
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.tellReading).editing, false)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.pickReplacement).replaceSheetOpen, true)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.save).changeCount, 1)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.tellPlay).editing, false)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.tellPlay).swapped, true)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.tapStretch).editing, false)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.toast).toastVisible, true)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.chips).readCount, 12)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.undoStrip).readCount, 22)
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.undoStrip).undoText, "Logged +5 pages · Sample week")
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.holdTidy).done, [0, 2, 3, 4, 7])
        XCTAssertEqual(TutorialCompleteBoardState.implied(step: L3.markDone).holdMenuOpen, true)
        XCTAssertNil(TutorialCompleteBoardState.implied(step: L3.markDone).moment)
        let bingo = TutorialCompleteBoardState.implied(step: L3.bingoMoment)
        XCTAssertEqual(bingo.moment, .bingo)
        XCTAssertEqual(bingo.done, [0, 2, 3, 4, 5, 7])
        XCTAssertEqual(bingo.spots(step: L3.bingoMoment), [])
        let tell = TutorialCompleteBoardState.implied(step: L3.tellLines)
        XCTAssertNil(tell.moment)
        XCTAssertEqual(tell.completeLines, [[3, 4, 5]])
        let finale = TutorialCompleteBoardState.implied(step: L3.finale)
        XCTAssertEqual(finale.done, [0, 2, 3, 4, 5, 7])
        XCTAssertEqual(finale.completeLines, [[3, 4, 5]])
        XCTAssertNil(finale.moment)
        XCTAssertNil(finale.stepOverride(step: L3.finale), "the catalog's line until the first tap")
        XCTAssertEqual(Set(finale.spots(step: L3.finale).map(\.id)), [.square(1), .square(6), .square(8)])
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
        coach.next()
        XCTAssertEqual(coach.session?.step, L2.tellSetup, "closing: no more events")
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
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).steps.count, 10)
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).steps.count, 14)
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).steps.count, 16)
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).barLabel, "Lesson 1 · Create a task")
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).barLabel, "Lesson 3 · Complete a board")
        XCTAssertEqual(TutorialCatalog.info(for: .completeBoard).steps.filter { $0.advance == .next && !$0.isTell }.count, 2, "two read-only steps besides the tells")
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).steps.filter { $0.advance == .next && !$0.isTell }.count, 1, "the window step")
        XCTAssertEqual(TutorialCatalog.info(for: .createTask).completeSecondary, .tasks)
        XCTAssertEqual(TutorialCatalog.info(for: .createBoard).completeSecondary, .create)
        XCTAssertNil(TutorialCatalog.info(for: .completeBoard).completeSecondary)
    }

    func test_catalog_everyCompactStepCarriesANoteAndNoBang() {
        for lesson in TutorialLessonID.middleRow {
            for (i, step) in TutorialCatalog.info(for: lesson).steps.enumerated() {
                XCTAssertFalse(step.text.contains("!"), "\(lesson) step \(i + 1)")
                if step.isTell {
                    XCTAssertNil(step.note)
                } else {
                    XCTAssertFalse(step.note?.isEmpty ?? true, "\(lesson) step \(i + 1) has a note")
                    XCTAssertFalse(step.note?.contains("!") ?? false)
                }
            }
        }
        XCTAssertEqual(TutorialCatalog.createTaskSteps[L1.special].resumedText, "Tap Special type.")
    }
}
