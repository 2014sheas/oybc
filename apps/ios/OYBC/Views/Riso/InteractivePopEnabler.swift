import SwiftUI
import UIKit

/// Keeps the interactive swipe-back working on a screen that hides the system navigation
/// bar (Task Detail's full-bleed hero, the play board's in-content header). Hiding the bar
/// or its back button disables `interactivePopGestureRecognizer`'s delegate; this restores it
/// for as long as the screen is visible and puts the previous delegate back on disappear.
/// Scoped — attach with `.background(InteractivePopEnabler())` on the screens that need it.
struct InteractivePopEnabler: UIViewControllerRepresentable {

    /// The delegate rule: begin only with something to pop to (a root screen must not
    /// swallow the gesture and freeze the stack).
    static func shouldBegin(viewControllerCount: Int) -> Bool { viewControllerCount > 1 }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var previousDelegate: UIGestureRecognizerDelegate?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            if recognizer.delegate !== self { previousDelegate = recognizer.delegate }
            recognizer.delegate = self
            recognizer.isEnabled = true
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            guard let recognizer = navigationController?.interactivePopGestureRecognizer, recognizer.delegate === self else { return }
            recognizer.delegate = previousDelegate
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            InteractivePopEnabler.shouldBegin(viewControllerCount: navigationController?.viewControllers.count ?? 0)
        }
    }
}
