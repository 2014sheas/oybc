import SwiftUI

// MARK: - Facsimile kit
//
// Shared parts of the tutorial's facsimile screens: the inert tab bar, the
// sheet panel the scripted sheets draw into, the lock chip a locked option
// carries, and a few row shapes the real screens share. Facsimiles copy the
// shipped screens' layout from the same Riso primitives, but never mount the
// real stateful views — the lesson is isolated from the user's data.

/// The app's bottom tab bar, drawn inert (one tab lit, nothing tappable).
struct TutorialTabBarFacsimile: View {
    enum Tab { case boards, tasks, create, profile }
    let active: Tab

    var body: some View {
        HStack(spacing: 0) {
            item("Boards", "square.grid.3x3", .boards)
            item("Tasks", "list.bullet", .tasks)
            item("Create", "plus.circle", .create)
            item("Profile", "person.circle", .profile)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.risoPaper2.opacity(0.6)))
                .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
        )
        .padding(.horizontal, 16)
        .tutorialInert()
    }

    private func item(_ label: String, _ symbol: String, _ tab: Tab) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular))
            Text(label).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tab == active ? Color.risoBlue : Color.risoMuted)
        .frame(maxWidth: .infinity)
    }
}

/// A scripted sheet, drawn inside the stage (never a real presentation, so it
/// cannot be swiped away): paper panel with rounded top corners, sitting
/// `top` points below the bar, over the dimmed screen behind it.
struct TutorialSheetPanel<Content: View>: View {
    /// Distance from the top of the stage content to the panel's top edge.
    var top: CGFloat = 12
    /// A 36×4 grabber under the top edge (the real sheets show one).
    var grabber: Bool = true
    /// A 2pt ink rule along the top edge (the square sheet's chrome).
    var topRule: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
            VStack(spacing: 0) {
                if topRule {
                    Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container)
                }
                if grabber {
                    Capsule()
                        .fill(Color.risoInk.opacity(0.2))
                        .frame(width: 36, height: 4)
                        .padding(.top, 10)
                        .padding(.bottom, 14)
                        .accessibilityHidden(true)
                }
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.risoPaper)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
            .shadow(color: Color.black.opacity(0.12), radius: 0, y: -1)
        }
    }
}

/// The 22pt lock chip a locked option carries (paper-2, keyline 1.5).
struct TutorialLockChip: View {
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: "lock")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Color.risoInk)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .accessibilityHidden(true)
    }
}

/// A locked choice in a segmented row or chip strip: muted text on paper, a
/// keyline at 40% ink, an optional lock glyph. Inert.
struct TutorialLockedSegment: View {
    let label: String
    var fontSize: CGFloat = 13
    var showsLock: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if showsLock {
                Image(systemName: "lock").font(.system(size: 10, weight: .bold))
            }
            Text(label).font(.risoHead(fontSize, .bold))
        }
        .foregroundStyle(Color.risoMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, fontSize >= 13 ? 10 : 7)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk.opacity(0.4), lineWidth: Riso.Keyline.container))
        .tutorialInert()
    }
}

/// A plain segment (on = blue fill / paper text, off = paper-2 / ink) as the
/// card `RisoSegmented` draws it. Inert unless given an action.
struct TutorialSegment: View {
    let label: String
    var isOn: Bool = false
    var fontSize: CGFloat = 13
    var action: (() -> Void)? = nil

    var body: some View {
        let body = Text(label)
            .font(.risoHead(fontSize, .bold))
            .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, fontSize >= 13 ? 10 : 7)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(isOn ? Color.risoBlue : Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        if let action {
            Button(action: action) { body }.buttonStyle(.plain)
        } else {
            body.tutorialInert()
        }
    }
}

/// The search field the Tasks tab and the sheets draw (inert).
struct TutorialSearchFieldFacsimile: View {
    let placeholder: String
    var fontSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .bold))
            Text(placeholder).font(.risoHead(fontSize, .bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.risoMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper2)
        .tutorialInert()
    }
}

/// The small ✕ glyph button the sheets and rows carry.
struct TutorialCloseGlyph: View {
    var size: CGFloat = 13
    var dimmed: Bool = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Color.risoMuted)
            .frame(width: 28, height: 28)
            .opacity(dimmed ? 0.35 : 1)
    }
}

/// A full-screen-ish scrim behind a scripted sheet (the screen under it dims
/// like a real presentation). Inert.
struct TutorialBehindSheetDim: View {
    var body: some View {
        Color.black.opacity(0.18).ignoresSafeArea().tutorialInert()
    }
}
