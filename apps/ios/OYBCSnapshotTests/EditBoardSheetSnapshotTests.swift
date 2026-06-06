import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for M2 — the `BoardSetupFormView` in `.editActive` mode,
/// which is rendered inside `EditBoardSheet`.
///
/// We snapshot the form body rather than the full sheet because `EditBoardSheet`
/// depends on `@EnvironmentObject AuthService` and starts async DB queries in
/// `onAppear` — both of which are brittle in a headless snapshot harness.
/// The form itself is a pure presentational surface that is safe to snapshot
/// in isolation.
final class EditBoardSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Helpers

    /// Returns a `BoardSetupFormView` wired in `.editActive` mode with the
    /// given overrides. This mirrors exactly how `EditBoardSheet` constructs
    /// the view.
    private func makeEditForm(
        name: String = "Spring Goals",
        timeframe: Timeframe = .monthly,
        centerType: CenterSquareType = .free,
        centerCustomName: String = "",
        chosenCenterDisabled: Bool = false
    ) -> some View {
        BoardSetupFormView(
            mode: .editActive,
            name: .constant(name),
            timeframe: .constant(timeframe),
            customStartDate: .constant(Date(timeIntervalSince1970: 1_743_465_600)), // 2026-04-01
            customEndDate: .constant(Date(timeIntervalSince1970: 1_746_057_600)),   // 2026-04-30
            centerType: .constant(centerType),
            centerCustomName: .constant(centerCustomName),
            weekStartDay: "monday",
            chosenCenterDisabled: chosenCenterDisabled
        )
    }

    // MARK: - Board-size read-only chip (rendered by EditBoardSheet wrapper)

    /// Verifies the immutable-chip block that wraps the form.
    func testReadOnlySizeChip() {
        let view = Form {
            // Mirror what EditBoardSheet renders above the form body.
            Section {
                HStack {
                    Text("Board size")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("5×5")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                    Text("(immutable)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Immutable")
            } footer: {
                Text("Board size cannot be changed on an active board.")
            }
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200)),
            record: recordMode
        )
    }

    // MARK: - Form in edit-active mode

    /// Monthly timeframe, FREE center — the common initial state when the sheet opens.
    func testEditActiveFormMonthlyFree() {
        let view = Form {
            makeEditForm(timeframe: .monthly, centerType: .free)
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600)),
            record: recordMode
        )
    }

    /// Custom timeframe, showing the date pickers.
    func testEditActiveFormCustomDates() {
        let view = Form {
            makeEditForm(timeframe: .custom, centerType: .free)
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    /// CHOSEN center disabled because the board has no placed tasks.
    /// The guard note should appear under the center section.
    func testEditActiveFormChosenDisabledNoTasks() {
        let view = Form {
            makeEditForm(centerType: .free, chosenCenterDisabled: true)
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600)),
            record: recordMode
        )
    }

    /// CUSTOM_FREE center — verifies the custom-name text field renders.
    func testEditActiveFormCustomFreeCenter() {
        let view = Form {
            makeEditForm(centerType: .customFree, centerCustomName: "Free Space")
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600)),
            record: recordMode
        )
    }

    /// Weekly timeframe — ensures the Timeframe picker shows weekly as selected.
    func testEditActiveFormWeeklyTimeframe() {
        let view = Form {
            makeEditForm(timeframe: .weekly, centerType: .none)
        }

        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 600)),
            record: recordMode
        )
    }
}
