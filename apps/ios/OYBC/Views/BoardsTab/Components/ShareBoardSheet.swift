import SwiftUI
import UIKit
import Photos

// MARK: - ShareBoardSheet

/// Bottom sheet opened from the Bingo / Greenlog moment overlay's share button
/// (handoff 5c / 5d). `kind` picks the poster fill, badge, title, filename and
/// share text (`BoardShareContent`).
///
/// The poster is the raster target: a 9:16 `ShareStoryPoster` (236 x 420 pt,
/// static colours) showing the board's real end-state cells from
/// `momentPosterCells`, with a "Show task names" toggle (default on) and an
/// always-on stats row. Documented divergence from web: a "Copy link" row and
/// four icon targets (Messages / Stories / Save image / More) instead of web's
/// Share + Save image buttons.
///
/// - Parameters:
///   - content: The moment kind plus the board's numbers and streak.
///   - cells: The poster's cells in their end state (`momentPosterCells`).
///   - boardId: Used for the copy-link slug.
///   - onDismiss: Called when the user taps Done or dismisses the sheet.
struct ShareBoardSheet: View {

    // MARK: - Props

    let content: BoardShareContent
    let cells: [PosterCell]
    let boardId: String
    var onDismiss: (() -> Void)? = nil

    /// - Parameter initialShowTaskNames: Initial "Show task names" value (snapshot seam).
    init(
        content: BoardShareContent, cells: [PosterCell], boardId: String,
        onDismiss: (() -> Void)? = nil,
        initialShowTaskNames: Bool = BoardShareContent.showTaskNamesDefault
    ) {
        self.content = content
        self.cells = cells
        self.boardId = boardId
        self.onDismiss = onDismiss
        _showTaskNames = State(initialValue: initialShowTaskNames)
    }

    // MARK: - State

    @State private var showTaskNames: Bool
    @State private var linkCopied: Bool = false
    @State private var shareItem: ShareActivityItem? = nil
    /// Transient feedback for the "Save image" action (success or failure).
    @State private var saveToast: String? = nil

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
                Text(content.sheetTitle)
                    .font(.risoHead(17, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Button {
                    onDismiss?()
                } label: {
                    Text("Done")
                        .font(.risoHead(12, .extraBold))
                        // On the gold pill — non-inverting ink for dark mode.
                        .foregroundStyle(Color.risoInkStatic)
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
                    posterElevated
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    // ── Show task names toggle ──
                    showNamesRow
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
        .overlay(alignment: .top) {
            if let saveToast {
                Text(saveToast)
                    .font(.risoHead(12, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Capsule().fill(Color.risoInk))
                    .padding(.top, 56)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityViewController(activityItems: item.items)
        }
    }

    // MARK: - Poster

    /// The raster target — the exact view `ImageRenderer` rasterizes.
    private var poster: ShareStoryPoster {
        ShareStoryPoster(content: content, cells: cells, showTaskNames: showTaskNames)
    }

    /// The preview in the sheet: the poster with its keyline + hard shadow
    /// (preview chrome only — never part of the export).
    private var posterElevated: some View {
        poster
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.risoInk)
                    .offset(x: Riso.Shadow.card, y: Riso.Shadow.card)
            )
    }

    // MARK: - Show task names toggle row

    @ViewBuilder
    private var showNamesRow: some View {
        Button {
            showTaskNames.toggle()
        } label: {
            HStack(spacing: 10) {
                // Ink pill switch
                RisoInkSwitch(isOn: showTaskNames)
                Text("Show task names")
                    .font(.risoHead(13.5, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
            }
            .contentShape(Rectangle()) // whole row (incl. the Spacer) is the tap target
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(showTaskNames ? "On" : "Off")
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

    /// Renders the poster to a `UIImage` via `ImageRenderer` at 2x
    /// (472 x 840 px), forced to the light palette.
    ///
    /// - Returns: A rasterized PNG-ready `UIImage`, or `nil` if rendering fails.
    @MainActor
    private func renderPosterImage() -> UIImage? {
        let renderer = ImageRenderer(content: poster.environment(\.colorScheme, .light))
        renderer.scale = 2
        return renderer.uiImage
    }

    /// Presents `UIActivityViewController` with the poster PNG (named
    /// `{slug}-{kind}.png`) and the kind's share text.
    private func presentShareSheet() {
        _Concurrency.Task { @MainActor in
            guard let image = renderPosterImage() else { return }
            var poster: Any = image
            if let data = image.pngData() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(content.fileName)
                if (try? data.write(to: url, options: .atomic)) != nil { poster = url }
            }
            shareItem = ShareActivityItem(items: [
                PosterActivityItem(item: poster, title: content.shareTitle), content.shareText,
            ])
        }
    }

    /// Renders the poster card and saves it to the Photos library.
    ///
    /// Uses `PHPhotoLibrary.performChanges` (not the fire-and-forget
    /// `UIImageWriteToSavedPhotosAlbum`) so a denied permission or write
    /// failure surfaces to the user via `saveToast` instead of silently
    /// doing nothing.
    private func saveImageToPhotos() {
        _Concurrency.Task { @MainActor in
            guard let image = renderPosterImage() else {
                showSaveToast("Couldn't render the image.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                showSaveToast("Saved to Photos")
            } catch {
                showSaveToast("Couldn't save — check Photos access in Settings.")
            }
        }
    }

    /// Shows a transient toast for ~2.5s (mirrors the copy-link reset cadence).
    @MainActor
    private func showSaveToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) { saveToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.16)) { saveToast = nil }
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

    /// The icon tile's side. A fixed size: inside the four-up `HStack` the
    /// old `maxWidth: .infinity` + `aspectRatio(1)` pair had no definite
    /// width to square against, so the tiles collapsed over their labels.
    private static let tileSide: CGFloat = 56

    var body: some View {
        VStack(spacing: 7) {
            // The tile is the button; its hard shadow belongs to the tile
            // alone (the label sits under it, unshadowed).
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: Self.tileSide, height: Self.tileSide)
                    .background(RoundedRectangle(cornerRadius: 14).fill(fill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )
            }
            .buttonStyle(ShareTargetButtonStyle())
            .accessibilityLabel(label)
            Text(label)
                .font(.risoHead(10.5, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
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

#Preview("Share bingo sheet") {
    let replay = BoardMomentReplay(order: [], freeIdx: nil, lineClosureBeat: [:], completedTasks: 0, totalTasks: 9, size: 3)
    Color.risoBlue.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ShareBoardSheet(
                content: BoardShareContent(
                    kind: .bingo, boardName: "Weekly Wellness", completedTasks: 0, totalTasks: 9,
                    linesCompleted: 1, boardSize: 3
                ),
                cells: momentPosterCells(
                    replay: replay,
                    cells: (0..<9).map { PosterCellInput(idx: $0, label: "Task \($0)", type: .normal, isFree: false) },
                    kind: .bingo
                ),
                boardId: "board-abc-123-def"
            )
            .presentationDetents([.medium, .large])
        }
}
