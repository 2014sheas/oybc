import SwiftUI

/// The one counter-kind picker (docs/COUNTER_KINDS.md §5): a three-segment
/// card `RisoSegmented` with the D4 lock states. Web twin: `KindPicker.tsx`.
///
/// When `onRequest` is set a tap on a live segment calls it instead of
/// writing `selection`, so the caller can confirm Continuous → Discrete
/// (`KindSwitchConfirmView`, Task 8) and write the binding itself.
struct KindPickerView: View {
    @Binding var selection: CountKind
    let lock: KindPickerLock
    var onRequest: ((CountKind) -> Void)? = nil

    var body: some View {
        RisoSegmented(
            options: CountKind.allCases.map { (value: $0, label: $0.label) },
            selection: Binding(
                get: { selection },
                set: { next in
                    guard next != selection else { return }
                    if let onRequest { onRequest(next) } else { selection = next }
                }
            ),
            lockedValues: Set(CountKind.allCases.filter { isKindSegmentLocked(lock, segment: $0) }),
            lockGlyphValues: Set(CountKind.allCases.filter { kindSegmentShowsLock(lock, segment: $0, selected: selection) })
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kind")
    }
}

/// A linked row's kind (D5): kind chip + shared dots, then
/// "{counter} · {all-time} all-time". Never a picker.
struct KindTagView: View {
    let kind: CountKind
    var counterName: String? = nil
    var lifetime: CountValue? = nil
    /// The compact chip a dense row carries (quick-add match rows): tighter
    /// padding, a 1.5pt keyline, smaller type and dots.
    var dense: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: dense ? 5 : 6) {
                Text(kind.label).font(.risoHead(dense ? 11 : 12, .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 2) {
                    Circle().frame(width: dense ? 4 : 5, height: dense ? 4 : 5)
                    Circle().frame(width: dense ? 4 : 5, height: dense ? 4 : 5)
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, dense ? 8 : 10)
            .padding(.vertical, dense ? 3 : 6)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: dense ? Riso.Keyline.dense : Riso.Keyline.container)
            )
            if let counterName, let lifetime {
                Text("\(counterName) · \(formatCountTotal(lifetime, kind: kind)) all-time")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }
}

extension KindTagView {
    /// An existing linked row's tag (spec §5): the family root's kind,
    /// pair-derived counter name (title fallback) and all-time total — the
    /// same name / lifetime the create forms' auto-link hint shows
    /// (`findLinkableCounter`). Without a root, the row's own kind only.
    /// Web twin: `linkedKindTagProps` (`LinkedKindTag.tsx`).
    ///
    /// - Parameters:
    ///   - task: The linked row (`sharedCounterId` set).
    ///   - root: The family root, or nil while it can't be read.
    init(linkedTask task: Task, root: Task?) {
        guard let root else {
            self.init(kind: resolveCountKind(task.countKind))
            return
        }
        self.init(
            kind: resolveCountKind(root.countKind),
            counterName: CounterSettings.counterDisplayName(root),
            lifetime: root.currentCount ?? 0
        )
    }
}

extension AppDatabase {
    /// The family root of a linked row, or nil (unlinked, missing, or a read
    /// error) — feeds `KindTagView(linkedTask:root:)`.
    func linkedCounterRoot(of task: Task) -> Task? {
        guard let rootId = task.sharedCounterId else { return nil }
        return try? fetchTask(id: rootId)
    }
}
