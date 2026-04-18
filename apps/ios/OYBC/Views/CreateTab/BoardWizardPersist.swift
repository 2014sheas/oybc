import Foundation

/// Per-cell placement for the wizard's preview grid and the persisted
/// `BoardTask` rows. `nil` slots only appear at the reserved centre
/// cell for FREE / CUSTOM_FREE centre types. Mirrors web's
/// `WizardPlacement`.
typealias WizardPlacement = [Task?]

/// Resolution result for the wizard's start/end dates. Mirrors web's
/// `ResolvedDates` discriminated union.
enum ResolvedWizardDates {
    case ok(start: String, end: String)
    case error(String)
}

enum WizardStatus: String {
    case active
    case draft
}

/// Builds the full placement array for the wizard's current selection +
/// geometry. Used as the single source of truth for both the preview
/// grid and the `saveBoardTask` calls so what the user sees and what
/// gets persisted are identical. iOS twin of web's
/// `buildWizardPlacement`.
func buildWizardPlacement(
    controller: BoardWizardViewModel,
    library: TaskLibraryViewModel
) -> WizardPlacement {
    let size = controller.size
    let total = size * size
    let isOdd = size % 2 != 0
    let centerIdx = (size / 2) * size + (size / 2)

    let selected = library.libraryTasks.filter { controller.selectedTaskIds.contains($0.id) }

    let chosenCenter: Task? = {
        guard isOdd, controller.centerType == .chosen, let id = controller.centerTaskId else {
            return nil
        }
        return selected.first(where: { $0.id == id })
    }()
    let others: [Task] = chosenCenter != nil
        ? selected.filter { $0.id != chosenCenter!.id }
        : selected
    let ordered = controller.isRandomized
        ? Shuffle.fisherYatesShuffle(others)
        : others

    var grid: WizardPlacement = Array(repeating: nil, count: total)
    var oi = 0
    for i in 0..<total {
        if i == centerIdx && isOdd {
            if let center = chosenCenter {
                grid[i] = center
                continue
            }
            if controller.centerType == .free || controller.centerType == .customFree {
                // Reserved cell — leave nil; BingoBoard renders the FREE label.
                continue
            }
            // NONE on odd: fall through and place a regular task here.
        }
        if oi < ordered.count {
            grid[i] = ordered[oi]
            oi += 1
        }
    }
    return grid
}

/// Resolves local-ISO start/end strings for the wizard's current
/// timeframe. Non-custom timeframes use `computeTimeframeBoundaries`;
/// custom timeframes require non-empty `customStartDate` /
/// `customEndDate` and validate the range. Mirrors web's
/// `resolveWizardDates`.
func resolveWizardDates(controller: BoardWizardViewModel) -> ResolvedWizardDates {
    if controller.timeframe != .custom {
        guard let b = controller.computedBoundaries else {
            return .error("Could not resolve timeframe boundaries.")
        }
        return .ok(start: wizardLocalISOString(b.start), end: wizardLocalISOString(b.end))
    }
    guard !controller.customStartDate.isEmpty,
          !controller.customEndDate.isEmpty,
          let s = parseWizardCalendarDate(controller.customStartDate),
          let e = parseWizardCalendarDate(controller.customEndDate)
    else {
        return .error("Pick a start and end date.")
    }
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: s)
    let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!
    let dayEnd = nextDay.addingTimeInterval(-0.001)
    if dayEnd < dayStart {
        return .error("End date must be on or after the start date.")
    }
    return .ok(start: wizardLocalISOString(dayStart), end: wizardLocalISOString(dayEnd))
}

/// Writes the wizard's state to GRDB.
///
/// - **Fresh create** (`draftBoardId` nil): inserts a new `Board`
///   (`status=active` or `status=draft`) plus per-cell `BoardTask`
///   rows in a single transaction. Version always starts at 1.
/// - **Draft update** (`draftBoardId` set): updates the existing
///   `Board` with new field values + target status (version bump
///   via `saveBoard`), hard-deletes all of its `BoardTask` rows, then
///   inserts the new placement.
///
/// Runs on a background queue; dispatches the provided callbacks on
/// the main queue. Callers should already have validated
/// `resolveWizardDates` before invoking this.
func persistWizardBoard(
    controller: BoardWizardViewModel,
    userId: String,
    placement: WizardPlacement,
    dates: (start: String, end: String),
    status: WizardStatus,
    onSuccess: @escaping (_ boardId: String) -> Void,
    onError: @escaping (_ message: String) -> Void
) {
    let trimmedName = controller.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let size = controller.size
    let isOdd = size % 2 != 0
    let centerRow = size / 2
    let centerCol = size / 2
    let centerType = controller.centerType
    let customCenterName: String? = centerType == .customFree
        ? controller.centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
    let chosenCenterId: String? = centerType == .chosen ? controller.centerTaskId : nil
    let draftBoardId = controller.draftBoardId
    let now = AppDatabase.currentTimestamp()
    let boardId = draftBoardId ?? AppDatabase.generateUUID()
    let boardStatusRaw = status == .active ? "active" : "draft"
    let capturedTimeframe = controller.timeframe
    let capturedIsRandomized = controller.isRandomized

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let isUpdate = draftBoardId != nil
            let existing: Board? = isUpdate ? try AppDatabase.shared.fetchBoard(id: boardId) : nil

            var boardDict: [String: Any] = [
                "id": boardId,
                "userId": userId,
                "name": trimmedName,
                "status": boardStatusRaw,
                "boardSize": size,
                "timeframe": capturedTimeframe.rawValue,
                "startDate": dates.start,
                "endDate": dates.end,
                "centerSquareType": centerType.rawValue,
                "isRandomized": capturedIsRandomized,
                "totalTasks": size * size,
                "completedTasks": 0,
                "linesCompleted": 0,
                "createdAt": existing?.createdAt ?? now,
                "updatedAt": now,
                "version": (existing?.version ?? 0) + 1,
                "isDeleted": false,
            ]
            if let name = customCenterName, !name.isEmpty {
                boardDict["centerSquareCustomName"] = name
            }
            if let id = chosenCenterId {
                boardDict["centerTaskId"] = id
            }

            let boardData = try JSONSerialization.data(withJSONObject: boardDict)
            let board = try JSONDecoder().decode(Board.self, from: boardData)

            var boardTasks: [BoardTask] = []
            for (i, slot) in placement.enumerated() {
                guard let task = slot else { continue }
                let row = i / size
                let col = i % size
                let isCenterPos = isOdd && row == centerRow && col == centerCol
                let bt = BoardTask.makePlayground(
                    boardId: boardId,
                    taskId: task.id,
                    row: row,
                    col: col,
                    now: now,
                    isCenter: isCenterPos && (centerType == .chosen || centerType == .none)
                )
                boardTasks.append(bt)
            }

            if isUpdate {
                try AppDatabase.shared.deleteBoardTasksForBoard(boardId: boardId)
            }
            try AppDatabase.shared.write { db in
                try board.save(db)
                for bt in boardTasks {
                    try bt.save(db)
                }
            }

            DispatchQueue.main.async { onSuccess(boardId) }
        } catch {
            DispatchQueue.main.async {
                onError(error.localizedDescription)
            }
        }
    }
}
