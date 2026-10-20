import Foundation

// MARK: - MomentPresentation samples

/// A fully-complete sample 5×5 board for the tutorial's "Preview a GREENLOG"
/// and the moment snapshot tests — no database, deterministic.
extension MomentPresentation {

    private static let sampleTitles = [
        "Run 5k", "Read 20 pages", "Call mom", "Meditate", "Cook dinner",
        "Drink 8 glasses", "No sugar", "Stretch", "Journal", "Inbox zero",
        "Walk 10k steps", "Floss", "FREE", "Lift weights", "Budget review",
        "Sleep by 11", "Language lesson", "Water plants", "Write 500 words", "Tidy desk",
        "Bike to work", "Learn a song", "Early rise", "Screen-free hour", "Call a friend",
    ]

    /// Every square complete, landing row-major; a FREE centre.
    static var greenlogSample: MomentPresentation {
        let freeIdx = 12
        let landing = (0..<25).filter { $0 != freeIdx }
        let replay = BoardMomentReplay(
            order: landing.map { MomentOrderEntry(boardTaskId: "sample-\($0)", idx: $0, completedAt: nil) },
            freeIdx: freeIdx, lineClosureBeat: [:], completedTasks: 25, totalTasks: 25, size: 5
        )
        let cells = (0..<25).map { i in
            i == freeIdx
                ? MomentCellInput(idx: i, slot: .free)
                : MomentCellInput(idx: i, title: sampleTitles[i], endCompleted: true)
        }
        return MomentPresentation(kind: .greenlog, replay: replay, cells: cells)
    }
}

extension MomentPresentation {

    /// The tutorial Greenlog (all nine lessons done): the nine lesson titles as
    /// normal cells on a 3×3 with no free square, landing row-major.
    static var tutorialGreenlog: MomentPresentation {
        let titles = TutorialCatalog.titles
        let replay = BoardMomentReplay(
            order: titles.indices.map { MomentOrderEntry(boardTaskId: "tutorial-\($0)", idx: $0, completedAt: nil) },
            freeIdx: nil, lineClosureBeat: [:], completedTasks: 9, totalTasks: 9, size: 3
        )
        let cells = titles.enumerated().map { MomentCellInput(idx: $0.offset, title: $0.element, endCompleted: true) }
        return MomentPresentation(kind: .greenlog, replay: replay, cells: cells)
    }
}
