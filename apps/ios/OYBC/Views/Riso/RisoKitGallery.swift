#if DEBUG
import SwiftUI

/// Visual gallery of every Riso primitive — the verification surface for the
/// design-system foundation (snapshotted in light + dark by
/// `RisoKitSnapshotTests`, and usable as an Xcode preview). DEBUG-only; not
/// wired into production navigation.
struct RisoKitGallery: View {
    @State private var seg: String = "weekly"
    @State private var sampleText: String = "Run"
    @State private var sampleNum: String = "5"
    @State private var samplePass: String = "secret"

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Typography
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your boards").risoKicker()
                        Text("BINGO, but make it your goals.").risoH1()
                        Text("Section heading").risoH2()
                        Text("A quiet secondary subtitle line.").risoSub()
                        Text("Section label").risoSectionLabel()
                    }

                    sectionLabel("Buttons")
                    HStack(spacing: 10) {
                        RisoButton(title: "Neutral") {}
                        RisoButton(title: "Primary", kind: .primary) {}
                        RisoButton(title: "Blue", kind: .blue) {}
                    }
                    HStack(spacing: 10) {
                        RisoButton(title: "Create board", kind: .primary, systemImage: "sparkles", fullWidth: true, large: true) {}
                        RisoIconButton(systemImage: "plus") {}
                    }
                    HStack(spacing: 10) {
                        RisoButton(title: "Small", small: true) {}
                        RisoButton(title: "Add", kind: .green, small: true) {}
                        RisoButton(title: "Add", kind: .green, systemImage: "plus", small: true) {}
                    }

                    sectionLabel("Toolbar pills")
                    HStack(spacing: 10) {
                        RisoToolbarPill(title: "Done") {}
                        RisoToolbarPill(title: "Save") {}
                        RisoToolbarPill(title: "Delete", fill: .risoRed, foreground: .risoPaper) {}
                    }

                    sectionLabel("Chips")
                    HStack(spacing: 7) {
                        RisoChip(title: "All", isOn: false) {}
                        RisoChip(title: "Active", isOn: true) {}
                        RisoChip(title: "Completed", isOn: false) {}
                        RisoChip(title: "Filters", systemImage: "line.3.horizontal.decrease") {}
                    }

                    sectionLabel("Segmented — equal width")
                    RisoSegmented(
                        options: [("daily", "Daily"), ("weekly", "Weekly"), ("monthly", "Monthly"), ("yearly", "Yearly")],
                        selection: $seg
                    )

                    sectionLabel("Segmented — sizes to content + per-value color")
                    RisoSegmented(
                        options: [("daily", "Daily"), ("weekly", "Weekly"), ("monthly", "Monthly"), ("yearly", "Yearly")],
                        selection: $seg,
                        equalWidth: false,
                        selectedFill: { tf in
                            switch tf {
                            case "daily": return .risoGold
                            case "weekly": return .risoBlue
                            case "monthly": return .risoGreen
                            default: return .risoRed
                            }
                        }
                    )

                    sectionLabel("Text fields")
                    VStack(spacing: 8) {
                        RisoTextField(placeholder: "Task title", text: $sampleText)
                        RisoNumberField(placeholder: "Goal", text: $sampleNum)
                        RisoSecureField(placeholder: "Password", text: $samplePass)
                    }

                    sectionLabel("Progress")
                    RisoProgressBar(value: 0.56)
                    RisoProgressBar(value: 1.0, color: .risoGreen)

                    sectionLabel("Type badges")
                    HStack(spacing: 8) {
                        RisoTypeBadge(kind: .normal)
                        RisoTypeBadge(kind: .counting)
                        RisoTypeBadge(kind: .compound)
                        RisoTypeBadge(kind: .achievement)
                    }
                    HStack(spacing: 8) {
                        RisoTypeBadge(kind: .normal, style: .letterSquare)
                        RisoTypeBadge(kind: .counting, style: .letterSquare)
                        RisoTypeBadge(kind: .compound, style: .letterSquare)
                        RisoTypeBadge(kind: .achievement, style: .letterSquare)
                    }

                    sectionLabel("Card · hard shadow · halftone")
                    HStack(spacing: 12) {
                        Text("Elevated card")
                            .font(.risoBody(13, .bold))
                            .foregroundStyle(Color.risoInk)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .risoCard()
                            .risoHardShadow()
                        Text("Done")
                            .font(.risoBody(13, .bold))
                            .foregroundStyle(Color.risoPaper)
                            .frame(width: 64, height: 64)
                            .background(RoundedRectangle(cornerRadius: Riso.cellRadius).fill(Color.risoRed))
                            .risoHalftone()
                            .overlay(RoundedRectangle(cornerRadius: Riso.cellRadius).strokeBorder(Color.risoInk, lineWidth: 2))
                    }
                }
                .padding(Riso.gutter)
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ s: String) -> some View {
        Text(s).risoSectionLabel().padding(.top, 4)
    }
}

#Preview("Riso Kit — light") { RisoKitGallery() }
#Preview("Riso Kit — dark") { RisoKitGallery().environment(\.colorScheme, .dark) }
#endif
