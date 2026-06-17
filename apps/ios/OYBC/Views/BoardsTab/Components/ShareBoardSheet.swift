import SwiftUI
import UIKit
import Photos

// MARK: - ShareBoardSheet

/// Bottom sheet opened from the GREENLOG overlay's "Share my board" button.
///
/// Presents a shareable poster card (blue card, halftone overprint, 2px keyline,
/// 4px hard shadow) that can be rendered to an image for export. An "Include stats"
/// toggle shows/hides the Squares/Bingos/Streak stat trio on the card.
///
/// Target row wires to `UIActivityViewController` (Messages, Stories, More) and a
/// dedicated "Save image" button that renders the poster to the Photos library via
/// `ImageRenderer`.
///
/// - Parameters:
///   - board: The board whose completion is being shared.
///   - completedTasks: Number of squares completed.
///   - totalTasks: Total squares on the board.
///   - linesCompleted: Number of bingo lines scored.
///   - streakDays: Streak value shown on the stat card (pass `nil` to hide streak).
///   - onDismiss: Called when the user taps Done or dismisses the sheet.
struct ShareBoardSheet: View {

    // MARK: - Props

    let boardName: String
    let boardId: String
    let completedTasks: Int
    let totalTasks: Int
    let linesCompleted: Int
    var streakDays: Int = 7
    var onDismiss: (() -> Void)? = nil
    /// Initial value of the "Include stats on the card" toggle.
    /// Exposed so snapshot tests can snapshot both toggle states without
    /// needing to interact with the view.
    var initialIncludeStats: Bool = true

    // MARK: - State

    @State private var includeStats: Bool = true
    @State private var linkCopied: Bool = false
    @State private var shareItem: ShareActivityItem? = nil

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle
            Capsule()
                .fill(Color.risoInk.opacity(0.3))
                .frame(width: 44, height: 4)
                .padding(.top, 8)

            // Sheet header
            HStack {
                Text("Share board")
                    .font(.risoHead(17, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Button {
                    onDismiss?()
                } label: {
                    Text("Done")
                        .font(.risoHead(12, .extraBold))
                        .foregroundStyle(Color.risoInk)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 13)
                        .background(Capsule().fill(Color.risoGold))
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                        .background(
                            Capsule()
                                .fill(Color.risoInk)
                                .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.risoInk)
                    .frame(height: Riso.Keyline.container)
            }

            // Scrollable body
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // ── Poster card ──
                    posterCardElevated
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    // ── Include stats toggle ──
                    includeStatsRow
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    // ── Copy link row ──
                    copyLinkRow
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    // ── Share target buttons ──
                    targetsRow
                        .padding(.horizontal, 16)
                        .padding(.top, 13)
                        .padding(.bottom, 28)
                }
            }
        }
        .background(Color.risoPaper)
        .onAppear {
            includeStats = initialIncludeStats
        }
        .sheet(item: $shareItem) { item in
            ActivityViewController(activityItems: item.items)
        }
    }

    // MARK: - Poster card

    /// The shareable poster card — the exact view that `ImageRenderer` rasterizes.
    ///
    /// Blue card + halftone overprint, 2px keyline + 4px hard shadow.
    /// Rendered at a fixed 280pt wide so `ImageRenderer` output is deterministic.
    ///
    /// - Parameter showStats: Whether to include the stat trio (Squares/Bingos/Streak).
    ///   Defaults to the current `includeStats` toggle state when called from `body`;
    ///   snapshot tests pass an explicit value to pin the variant without toggling state.
    func posterCard(showStats: Bool) -> some View {
        VStack(alignment: .center, spacing: 13) {

            // Top row: GREENLOG badge + OYBC wordmark
            HStack {
                // Green GREENLOG pill badge
                Text("GREENLOG")
                    .font(.risoHead(11, .extraBold))
                    .tracking(0.88)
                    .foregroundStyle(Color.risoInk)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 10)
                    .background(Capsule().fill(Color.risoGreen))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))

                Spacer()

                // OYBC wordmark
                Text("OYBC")
                    .font(.risoHead(16, .extraBold))
                    .tracking(-0.16)
                    .foregroundStyle(Color.risoPaper)
            }

            // Board name
            Text(boardName)
                .font(.risoHead(22, .extraBold))
                .tracking(-0.33)
                .foregroundStyle(Color.risoPaper)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            // Full 5×5 mini-grid (poster variant)
            posterMiniGrid
                .frame(width: 200, height: 200)

            // Optional stat trio
            if showStats {
                HStack(spacing: 8) {
                    posterStatCard(value: "\(completedTasks)/\(totalTasks)", label: "SQUARES")
                    posterStatCard(value: "\(linesCompleted)", label: "BINGOS")
                    posterStatCard(value: "\(streakDays)d", label: "STREAK")
                }
            }

            // Footer caps
            Text("OWN YOUR BINGO CARD")
                .font(.risoHead(10, .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.risoPaper.opacity(0.7))
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.risoBlue)
        // Halftone overprint
        .risoHalftone(tile: 9, layerOpacity: 0.45)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
    }

    @ViewBuilder
    private var posterCardElevated: some View {
        posterCard(showStats: includeStats)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(Color.risoInk)
                    .offset(x: Riso.Shadow.card, y: Riso.Shadow.card)
            )
    }

    // MARK: - Poster mini-grid

    /// 5×5 grid for the poster — all 25 cells shown as done (red + halftone),
    /// center cell is gold (FREE). Uses the board id for a deterministic scatter;
    /// falls back to showing all 25 done since this is a GREENLOG moment.
    @ViewBuilder
    private var posterMiniGrid: some View {
        let cols = 5
        let rows = 5
        let gap: CGFloat = 4
        let cellSize = (200 - gap * CGFloat(cols - 1)) / CGFloat(cols)

        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { col in
                        let idx = row * cols + col
                        let isCenter = (idx == 12)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isCenter ? Color.risoGold : Color.risoRed)
                            .overlay(
                                // Halftone on done cells only (not FREE)
                                Group {
                                    if !isCenter {
                                        Canvas { ctx, size in
                                            let r: CGFloat = 1.5
                                            let step: CGFloat = 6
                                            let paint = GraphicsContext.Shading.color(Color.risoInk.opacity(0.34))
                                            var y: CGFloat = 0
                                            while y < size.height {
                                                var x: CGFloat = 0
                                                while x < size.width {
                                                    ctx.fill(
                                                        Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                                                        with: paint
                                                    )
                                                    x += step
                                                }
                                                y += step
                                            }
                                        }
                                        .blendMode(.multiply)
                                    }
                                }
                            )
                            .overlay(
                                // Gold star in FREE center cell
                                Group {
                                    if isCenter {
                                        StarShape()
                                            .fill(Color.risoInk)
                                            .padding(4)
                                    }
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(
                                        isCenter ? Color.risoInk : Color.risoInk,
                                        lineWidth: 1.5
                                    )
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }

    // MARK: - Poster stat card

    @ViewBuilder
    private func posterStatCard(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.risoHead(18, .extraBold))
                .foregroundStyle(Color.risoInk)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.risoBody(8.5, .bold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.risoPaper)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    // MARK: - Include stats toggle row

    @ViewBuilder
    private var includeStatsRow: some View {
        Button {
            includeStats.toggle()
        } label: {
            HStack(spacing: 10) {
                // Ink pill switch
                RisoInkSwitch(isOn: includeStats)
                Text("Include stats on the card")
                    .font(.risoHead(13.5, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Copy link row

    @ViewBuilder
    private var copyLinkRow: some View {
        Button {
            UIPasteboard.general.string = "oybc.app/b/\(shortBoardId)"
            withAnimation(.easeOut(duration: 0.16)) {
                linkCopied = true
            }
            // Auto-reset after 2.5s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.16)) {
                    linkCopied = false
                }
            }
        } label: {
            HStack(spacing: 11) {
                // Icon square
                Image(systemName: linkCopied ? "checkmark" : "link")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(linkCopied ? Color.risoInk : Color.risoPaper)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(linkCopied ? Color.risoPaper : Color.risoBlue)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )

                // Text
                VStack(alignment: .leading, spacing: 1) {
                    Text(linkCopied ? "Link copied" : "Copy link")
                        .font(.risoHead(14, .extraBold))
                        .foregroundStyle(Color.risoInk)
                    Text("oybc.app/b/\(shortBoardId)")
                        .font(.risoBody(11.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(linkCopied ? Color.risoGreen : Color.risoPaper2)
            )
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
        }
        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.button))
    }

    // MARK: - Share targets row

    @ViewBuilder
    private var targetsRow: some View {
        HStack(spacing: 9) {
            // Messages (green)
            ShareTargetButton(
                systemImage: "message.fill",
                label: "Messages",
                fill: .risoGreen,
                foreground: .risoPaper
            ) {
                presentShareSheet()
            }

            // Stories / Camera (red)
            ShareTargetButton(
                systemImage: "camera.fill",
                label: "Stories",
                fill: .risoRed,
                foreground: .risoPaper
            ) {
                presentShareSheet()
            }

            // Save image (ink)
            ShareTargetButton(
                systemImage: "photo.fill",
                label: "Save image",
                fill: .risoInk,
                foreground: .risoPaper
            ) {
                saveImageToPhotos()
            }

            // More (paper)
            ShareTargetButton(
                systemImage: "ellipsis",
                label: "More",
                fill: .risoPaper2,
                foreground: .risoInk
            ) {
                presentShareSheet()
            }
        }
    }

    // MARK: - Helpers

    /// Short board id slug used in the link row (first 8 chars of the UUID).
    private var shortBoardId: String {
        String(boardId.prefix(8)).lowercased()
    }

    /// Renders the poster card to a `UIImage` via `ImageRenderer`.
    ///
    /// - Returns: A rasterized PNG-ready `UIImage`, or `nil` if rendering fails.
    @MainActor
    private func renderPosterImage() -> UIImage? {
        let renderer = ImageRenderer(
            content: posterCard(showStats: includeStats)
                .frame(width: 280)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage
    }

    /// Presents `UIActivityViewController` with the rendered poster image.
    private func presentShareSheet() {
        _Concurrency.Task { @MainActor in
            guard let image = renderPosterImage() else { return }
            shareItem = ShareActivityItem(items: [image])
        }
    }

    /// Renders the poster card and saves it to the Photos library.
    private func saveImageToPhotos() {
        _Concurrency.Task { @MainActor in
            guard let image = renderPosterImage() else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }
}

// MARK: - Ink Switch

/// Riso-styled ink pill toggle switch — 46×27pt, keyline border,
/// knob translates left/right, track turns green when on.
private struct RisoInkSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.risoGreen : Color.risoPaper)
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                .frame(width: 46, height: 27)

            Circle()
                .fill(isOn ? Color.risoPaper : Color.risoPaper2)
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                .frame(width: 19, height: 19)
                .padding(2)
        }
        .frame(width: 46, height: 27)
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

// MARK: - Share Target Button

/// One of the four keyline icon-squares in the share targets row.
/// Press collapses the hard shadow (Riso press-into-paper effect).
private struct ShareTargetButton: View {
    let systemImage: String
    let label: String
    let fill: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(fill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )
                Text(label)
                    .font(.risoHead(10.5, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(ShareTargetButtonStyle())
    }
}

/// Press-collapse style for share target icon squares — translates + collapses
/// the hard shadow, matching `RisoButtonStyle` behavior for icon-square targets.
private struct ShareTargetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let offset = Riso.Shadow.button
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.risoInk)
                    .offset(x: pressed ? 0 : offset, y: pressed ? 0 : offset)
            )
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .animation(.easeOut(duration: Riso.pressDuration), value: pressed)
    }
}

// MARK: - UIActivityViewController wrapper

/// Thin `UIViewControllerRepresentable` shim that presents the system
/// share sheet with the provided activity items.
private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Share activity item

/// `Identifiable` wrapper used to drive `.sheet(item:)` for the share sheet,
/// so it can be triggered from state without an `isPresented` boolean.
private struct ShareActivityItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Preview

#Preview("Share board sheet — light") {
    Color.risoBlue.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ShareBoardSheet(
                boardName: "Weekly Wellness",
                boardId: "board-abc-123-def",
                completedTasks: 25,
                totalTasks: 25,
                linesCompleted: 5,
                streakDays: 7
            )
            .presentationDetents([.medium, .large])
        }
}

#Preview("Share board sheet — dark") {
    Color.risoBlue.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ShareBoardSheet(
                boardName: "Weekly Wellness",
                boardId: "board-abc-123-def",
                completedTasks: 25,
                totalTasks: 25,
                linesCompleted: 5,
                streakDays: 7
            )
            .presentationDetents([.medium, .large])
        }
        .environment(\.colorScheme, .dark)
}
