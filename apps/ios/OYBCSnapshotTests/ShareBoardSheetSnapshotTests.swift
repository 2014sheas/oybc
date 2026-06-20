import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `ShareBoardSheet` and its sub-components.
///
/// `ShareBoardSheet` is prop-driven (board name + completion stats) so all
/// variants are seeded from `SnapshotFixtures` without any DB interaction.
/// Animated states (UIActivityViewController, Photos save) cannot be
/// captured in static snapshots — those require interactive user verification.
final class ShareBoardSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Full sheet (light + dark, with stats + without)

    func testShareSheetWithStatsLight() {
        let view = sheetHost(includeStats: true)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 700)), record: recordMode)
    }

    func testShareSheetWithStatsDark() {
        let view = sheetHost(includeStats: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testShareSheetWithoutStatsLight() {
        let view = sheetHost(includeStats: false)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }

    func testShareSheetWithoutStatsDark() {
        let view = sheetHost(includeStats: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 560), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Poster card (isolated — the renderable surface)

    func testPosterCardWithStatsLight() {
        let view = posterCardHost(includeStats: true)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 520)), record: recordMode)
    }

    func testPosterCardWithStatsDark() {
        let view = posterCardHost(includeStats: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testPosterCardWithoutStatsLight() {
        let view = posterCardHost(includeStats: false)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }

    func testPosterCardWithoutStatsDark() {
        let view = posterCardHost(includeStats: false)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 420), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Full `ShareBoardSheet` body, wrapped in a paper background.
    /// `includeStats` seeds `initialIncludeStats` so the toggle is pinned
    /// for the static snapshot render.
    @ViewBuilder
    private func sheetHost(includeStats: Bool) -> some View {
        ZStack {
            Color.risoBlue.ignoresSafeArea()
            // Present the sheet content directly (no interactive sheet presentation
            // needed for static snapshot — we snapshot the content view itself).
            VStack(spacing: 0) {
                ShareBoardSheet(
                    boardName: "Weekly Wellness",
                    boardId: "board-abc-123-def",
                    completedTasks: 25,
                    totalTasks: 25,
                    linesCompleted: 5,
                    streak: "7d",
                    initialIncludeStats: includeStats
                )
                .frame(maxWidth: .infinity)
                .background(Color.risoPaper)
            }
        }
    }

    /// Isolated poster card surface — the exact view that `ImageRenderer`
    /// rasterizes — on a paper background for legibility.
    /// Calls `posterCard(showStats:)` directly, bypassing `@State`.
    @ViewBuilder
    private func posterCardHost(includeStats: Bool) -> some View {
        let sheet = ShareBoardSheet(
            boardName: "Weekly Wellness",
            boardId: "board-abc-123-def",
            completedTasks: 25,
            totalTasks: 25,
            linesCompleted: 5,
            streak: "7d"
        )
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            sheet.posterCard(showStats: includeStats)
                .frame(width: 280)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoInk)
                        .offset(x: Riso.Shadow.card, y: Riso.Shadow.card)
                )
                .padding(Riso.gutter + 4)
        }
    }
}
