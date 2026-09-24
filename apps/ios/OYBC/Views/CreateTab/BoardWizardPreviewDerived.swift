import Foundation

// MARK: - BoardWizardPreviewDerived
//
// The wizard Preview's member-rule DRY RUN (B3 RC6,
// docs/BOARD_SOURCES.md §Member rules). iOS twin of web's
// `apps/web/src/components/wizard/previewDerived.ts`.
//
// Step 3 previews the board a person is about to create. Since B2 the persist
// path no longer places every picked task verbatim: a counting member carrying
// a target/vary rule is replaced by a window-stamped DERIVED counter whose
// `maxCount` is the rolled target, and a One-square compound with re-targeted
// parts is replaced by a derived compound. Left alone, the Preview would show
// "Run 30 miles" for a cell the board will actually carry as "Run 24 miles".
//
// So the Preview runs the SAME planner (`BoardSources.planDerivedTasks`) over
// the same inputs and re-labels each cell the rules would re-mint with a
// synthetic stand-in `Task` — a display object, never a row:
//
//   • no DB writes — nothing here touches GRDB or the sync queue; the real
//     mint happens inside the board-create transaction
//     (`AppDatabase+DerivedCounters.swift`);
//   • `baselineByRootId` is empty — the baseline only affects a derived
//     counter's stored starting count, never the target or title this renders;
//   • the roll is a SAMPLE — the Preview seeds the planner from the Shuffle
//     nonce (so one nonce always previews the same numbers and Shuffle visibly
//     re-rolls), while persist mints with the platform rng. The board a person
//     gets carries a fresh roll inside the same range.
//
// One-off boards only. A repeating board's Preview is the 5b summary card — it
// has no cell grid to stand tasks in, and its targets are pro-rated per
// repeated window rather than once at create time.

/// Board id used when the wizard has no draft row yet. Derived ids are a pure
/// function of `(boardId, rootTaskId)` and this dry run never writes one, so
/// the value only has to be stable within a render.
let previewBoardId = "preview"

/// Warm-up steps discarded before the Preview's first roll.
///
/// The LCG's first outputs are an AFFINE function of its seed, so the
/// consecutive nonces a Shuffle button produces (0, 1, 2 …) yield first
/// samples ~0.0004 apart — every re-roll would land in the same bucket and
/// Shuffle would look broken on a board with a single varied member. Two steps
/// multiply the seed's influence by `a²` and decorrelate adjacent nonces
/// completely, while keeping one nonce ⇒ one preview.
private let previewRngWarmup = 2

/// Options ``buildWizardPlacement(controller:library:previewRules:)`` accepts
/// to run the Preview dry run.
struct PreviewRulesOptions: Equatable {
    /// The Preview's Shuffle nonce. A SEED, deliberately — not a generator.
    ///
    /// `buildWizardPlacement` builds a fresh ``makePreviewRng(shuffleNonce:)``
    /// per call, so every build for one seed reproduces the same preview.
    /// Handing a live generator across builds would make each build consume
    /// the NEXT samples: the grid would re-roll one frame after first paint,
    /// and again on any data-reload tick with no Shuffle — the late-mutation
    /// class this project has a standing rule about.
    let seed: UInt32
}

/// The seeded `[0, 1)` source the Preview rolls its targets from.
///
/// - Parameter shuffleNonce: The Preview's Shuffle counter (0 at mount).
/// - Returns: A generator that is deterministic per nonce and well-spread
///   across adjacent ones (see the warm-up note above).
func makePreviewRng(shuffleNonce: UInt32) -> () -> Double {
    var rng = SeededRng(seed: shuffleNonce)
    for _ in 0..<previewRngWarmup { _ = rng.next() }
    return { rng.next() }
}

/// The id→task universe the planner reads: the live library, this session's
/// not-yet-persisted pending tasks, and — last, so it wins — the placement's
/// own tasks, which `buildWizardPlacement` has already overlaid with any
/// staged inline edits. A member whose goal was just retyped in the pool row
/// previews against the NEW goal.
///
/// - Parameters:
///   - placement: The placement just computed.
///   - controller: Live wizard state.
///   - library: The live task library.
/// - Returns: Every id the plan can name, mapped to the task to read.
private func previewPlanTasksById(
    placement: WizardPlacement,
    controller: BoardWizardViewModel,
    library: TaskLibraryViewModel
) -> [String: Task] {
    var out: [String: Task] = [:]
    for task in library.libraryTasks { out[task.id] = task }
    for payload in controller.pendingTasks.values { out[payload.task.id] = payload.task }
    for case let task? in placement { out[task.id] = task }
    return out
}

/// Task id → the window of the source BOARD it was pulled from, keyed by every
/// id whose source window matters: each supplied member AND the children of a
/// compound member (a compound's parts pro-rate by the CHILD's id — see
/// `planDerivedTasks`'s `sourceWindowByTaskId`). Pool sources have no window
/// of their own and contribute nothing.
///
/// Mirrors the persist path's construction in `mintWizardDerivedRows`.
///
/// - Parameters:
///   - controller: Live wizard state (holds the per-source supply info).
///   - supplies: The Split-up-expanded supplies the plan runs over.
///   - childrenByCompoundId: Compound id → its child links.
/// - Returns: The source-window lookup the planner pro-rates against.
private func previewSourceWindowByTaskId(
    controller: BoardWizardViewModel,
    supplies: [BoardSources.ExpandedSupply],
    childrenByCompoundId: [String: [CompoundChild]]
) -> [String: BoardSources.BoardWindow] {
    var out: [String: BoardSources.BoardWindow] = [:]
    for supply in supplies {
        guard let window = controller.supplyInfoBySourceId[supply.source.sourceId]?.sourceWindow
        else { continue }
        for id in supply.supplyTaskIds {
            out[id] = window
            for link in childrenByCompoundId[id] ?? [] { out[link.childTaskId] = window }
        }
    }
    return out
}

/// The prospective board's window — the SAME resolution the Save handler
/// persists. A date validation error (an unfinished CUSTOM range) resolves to
/// a date-less window: the Save button surfaces the error, and a date-less
/// CUSTOM window has no knowable length, so `autoTarget` falls back to each
/// member's own goal until the range is finished (owner ruling 2026-09-21 —
/// auto targets are no longer recurring-only, so the window IS read on a
/// one-off plan).
///
/// - Parameter controller: Live wizard state.
/// - Returns: The window the plan stamps derived rows with.
private func previewWindow(controller: BoardWizardViewModel) -> BoardSources.BoardWindow {
    guard case .ok(let start, let end) = resolveWizardDates(controller: controller) else {
        return BoardSources.BoardWindow(timeframe: controller.timeframe)
    }
    return BoardSources.BoardWindow(
        timeframe: controller.timeframe, startDate: start, endDate: end
    )
}

/// Replace every placement cell the member rules would re-mint with a
/// synthetic stand-in carrying the rolled target and its generated title.
///
/// Pure and side-effect free. The planner is fed the placement's own order
/// (nils skipped), so cell *i*'s task maps positionally to `placementIds[i]` —
/// a replaced cell keeps its place, exactly as the persist path places it.
///
/// The stand-in copies the original task and overrides the four fields a
/// person can see change: `title`, `maxCount`, `action`, `unit` — plus the
/// window-stamped link (`sharedCounterId`/`startDate`/`endDate`/
/// `createdInWizard`) so its count resolves from the root's events in THIS
/// board's window, exactly as the minted row will (see the note at the swap). Its `id` stays the
/// ORIGINAL's. Derived COMPOUNDS are deliberately not stood in for.
///
/// - Parameters:
///   - placement: The placement `buildWizardPlacement` just computed.
///   - controller: Live wizard state (supplies, rules, window, manual ids).
///   - library: The live task library.
///   - rng: Seeded uniform `[0, 1)` source — one nonce, one preview.
/// - Returns: A new placement array; cells the rules don't touch are the
///   values the caller passed in.
func applyPreviewDerivedCells(
    placement: WizardPlacement,
    controller: BoardWizardViewModel,
    library: TaskLibraryViewModel,
    rng: () -> Double
) -> WizardPlacement {
    let tasksById = previewPlanTasksById(
        placement: placement, controller: controller, library: library
    )
    let childrenByCompoundId = controller.childrenByCompoundId
    // The controller's own Split-up expansion — every surface reads THIS
    // rather than re-deriving it.
    let supplies = controller.expandedSupplies

    let orderedIds: [String] = placement.compactMap { $0?.id }
    if orderedIds.isEmpty { return placement }

    let plan = BoardSources.planDerivedTasks(
        selectedIds: orderedIds,
        supplies: supplies,
        manualTaskIds: Array(controller.manualTaskIds),
        manualTaskVary: controller.manualTaskVary,
        boardId: controller.draftBoardId ?? previewBoardId,
        window: previewWindow(controller: controller),
        // One-off only — the Preview's cell grid doesn't exist for a repeating
        // board, and the caller gates on `!controller.isRecurring`.
        mode: .oneOff,
        tasksById: tasksById,
        childrenByCompoundId: childrenByCompoundId,
        sourceWindowByTaskId: previewSourceWindowByTaskId(
            controller: controller, supplies: supplies,
            childrenByCompoundId: childrenByCompoundId
        ),
        // Display only — a baseline shifts a derived counter's starting count,
        // never the target or the title this renders.
        baselineByRootId: [:],
        rng: rng
    )

    if plan.derivedTasks.isEmpty { return placement }

    // ── What a stand-in may and may not change ─────────────────────────────
    //
    // The stand-in keeps the ORIGINAL task's `id`. That is not cosmetic:
    // `saveWizardBoard` re-derives its own selection from the placement's ids
    // before minting the real derived rows. A preview-only derived id fed back
    // in would miss every `tasksById` lookup and be written STRAIGHT into
    // `board_tasks` — a placement row pointing at a task that does not exist
    // (and the pending-task drain would never see its original). Nothing
    // renders a cell's id, so keeping the original costs nothing and keeps the
    // preview and the persist path reading the same task graph.
    //
    // Counting members only, likewise deliberately. A One-square compound that
    // re-targets its parts is ALSO replaced at mint time (by a derived
    // compound), but nothing about that is visible on a CELL: same title, same
    // type, same operator — only its children's targets differ, and a cell
    // renders none of them. A derived compound id here would also orphan the
    // children lookup the cell's completion resolves through.
    var counterById: [String: BoardSources.DerivedTaskDraft] = [:]
    for draft in plan.derivedTasks { counterById[draft.id] = draft }

    var rolledByOriginalId: [String: BoardSources.DerivedTaskDraft] = [:]
    for (index, id) in orderedIds.enumerated() {
        guard index < plan.placementIds.count else { continue }
        let next = plan.placementIds[index]
        if next == id { continue }
        if let counter = counterById[next] { rolledByOriginalId[id] = counter }
    }
    if rolledByOriginalId.isEmpty { return placement }

    return placement.map { cell in
        guard let task = cell, let counter = rolledByOriginalId[task.id] else { return cell }
        var standIn = task
        standIn.title = counter.title
        standIn.maxCount = counter.maxCount
        standIn.action = counter.action.isEmpty ? nil : counter.action
        standIn.unit = counter.unit.isEmpty ? nil : counter.unit
        // The stand-in IS the counter the persist path will mint: a
        // window-stamped derived row on THIS board's window, so it resolves
        // the way the real cell will (`resolveLinkedCounterDisplay` — the
        // ROOT's increments inside `[startDate, endDate]`), never an
        // original's own window (a pulled member that is itself
        // window-stamped carries its SOURCE board's window) and never a
        // root's lifetime. The mirror columns are zeroed: they are not read
        // for a window-stamped row and must not leak into a lifetime reader.
        standIn.sharedCounterId = counter.rootTaskId
        standIn.startDate = counter.startDate
        standIn.endDate = counter.endDate
        standIn.createdInWizard = true
        standIn.currentCount = 0
        standIn.baseline = 0
        return standIn
    }
}
