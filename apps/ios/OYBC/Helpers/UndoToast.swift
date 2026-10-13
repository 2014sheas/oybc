import SwiftUI
import UIKit

/// Shared behaviour of every Undo toast (owner rule 2026-10-13: an Undo toast
/// must not get in the way): a short life, and any other touch dismisses it.
/// Web twins: `UNDO_TOAST_MS` (`@oybc/shared`) + `useDismissOnOutsideInteraction`.
enum UndoToast {
    /// How long an Undo toast stays up before it dismisses itself (seconds).
    static let dismissDelay: TimeInterval = 2.5

    /// `dismissDelay` for `Task.sleep(nanoseconds:)`.
    static var dismissDelayNanoseconds: UInt64 { UInt64(dismissDelay * 1_000_000_000) }
}

extension View {
    /// Calls `action` on the user's next touch anywhere OUTSIDE this view — a
    /// tap, the start of a scroll or drag — without consuming or delaying that
    /// touch (it still does its own job). Touches inside (the Undo button) are
    /// ignored. Used by transient surfaces such as Undo toasts.
    ///
    /// - Parameter action: Runs on the main queue after an outside touch begins.
    func dismissOnOutsideTouch(perform action: @escaping () -> Void) -> some View {
        background(OutsideTouchObserver(onOutsideTouch: action))
    }
}

/// A zero-interaction UIKit view, sized to its SwiftUI host, that watches the
/// whole window for touches through a non-cancelling recognizer.
private struct OutsideTouchObserver: UIViewRepresentable {
    let onOutsideTouch: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.onOutsideTouch = onOutsideTouch
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onOutsideTouch = onOutsideTouch
    }

    final class ObserverView: UIView {
        var onOutsideTouch: (() -> Void)?
        private var recognizer: TouchBeganRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            guard let window else { return }
            let watcher = TouchBeganRecognizer { [weak self] touch in
                guard let self, self.window != nil else { return }
                guard !self.bounds.contains(touch.location(in: self)) else { return }
                DispatchQueue.main.async { self.onOutsideTouch?() }
            }
            window.addGestureRecognizer(watcher)
            recognizer = watcher
        }
    }
}

/// Reports every touch that begins in its window, then fails at once so it
/// never claims, cancels or delays the touch for anything else.
private final class TouchBeganRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onTouch: (UITouch) -> Void

    init(onTouch: @escaping (UITouch) -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onTouch(touch) }
        state = .failed
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
