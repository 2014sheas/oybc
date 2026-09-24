import Foundation
import FirebaseAuth

/// How the sign-in to the pre-existing account turned out.
enum CollisionSignInOutcome: Equatable, CaseIterable {
    case success, wrongPassword, cancelled, otherError
}

/// One step of the collision switch, in the order it must happen.
enum CollisionEffect: Equatable {
    /// Sign into the pre-existing account (while still anonymous).
    case signInExisting
    /// Drop the discarded guest's anon-stamped pending pushes.
    case clearAnonQueue
    /// Leave the upgrade surface — the app is now on the existing account.
    case switchSession
    /// Stop: the guest session + local data stay exactly as they were.
    case keepGuestData
}

/// Guest-upgrade collision "switch to the existing account" — the ordering
/// decision, extracted pure so the **verify-before-destroy** invariant
/// (docs/GUEST_MODE.md §Upgrade) is under test (`GuestCollisionSwitchTests`).
/// Mirrors web `firebase/guestCollisionSwitch.ts` 1:1.
@MainActor
enum GuestCollisionSwitch {
    /// The ordered effects for a sign-in outcome. Sign-in ALWAYS comes first;
    /// nothing destructive happens unless it succeeded.
    ///
    /// - Parameter outcome: Result of the sign-in to the existing account.
    /// - Returns: The full ordered plan (including the sign-in step itself).
    static func effects(for outcome: CollisionSignInOutcome) -> [CollisionEffect] {
        switch outcome {
        case .success: return [.signInExisting, .clearAnonQueue, .switchSession]
        case .wrongPassword, .cancelled, .otherError: return [.signInExisting, .keepGuestData]
        }
    }

    /// Classifies a sign-in failure (never returns `.success`).
    ///
    /// - Parameter error: The error thrown by the sign-in.
    /// - Returns: The failure outcome.
    static func classify(_ error: Error) -> CollisionSignInOutcome {
        if AuthService.isAuthCancellation(error) { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.wrongPassword.rawValue
            || nsError.code == AuthErrorCode.invalidCredential.rawValue {
            return .wrongPassword
        }
        return .otherError
    }

    /// Executes the collision switch strictly in `effects(for:)` order. If the
    /// sign-in throws, the plan for that failure outcome takes over from its
    /// sign-in step and the sign-in error is rethrown so the caller can surface
    /// it, having destroyed nothing.
    ///
    /// - Parameters:
    ///   - signInExisting: Signs into the pre-existing account.
    ///   - clearAnonQueue: Clears the anon sync queue.
    ///   - switchSession: Leaves the upgrade surface.
    /// - Throws: The sign-in error on any failed sign-in.
    static func run(
        signInExisting: () async throws -> Void,
        clearAnonQueue: () -> Void,
        switchSession: () -> Void
    ) async throws {
        let plan = effects(for: .success)
        let signInAt = plan.firstIndex(of: .signInExisting) ?? 0
        func perform(_ steps: ArraySlice<CollisionEffect>) async throws {
            for step in steps {
                switch step {
                case .signInExisting: try await signInExisting()
                case .clearAnonQueue: clearAnonQueue()
                case .switchSession: switchSession()
                case .keepGuestData: break // no-op marker: nothing to undo
                }
            }
        }
        try await perform(plan[..<signInAt])
        do {
            try await signInExisting()
        } catch {
            let failurePlan = effects(for: classify(error))
            let resumeAt = (failurePlan.firstIndex(of: .signInExisting) ?? -1) + 1
            try await perform(failurePlan[resumeAt...])
            throw error
        }
        try await perform(plan[(signInAt + 1)...])
    }
}
