import SwiftUI
import AuthenticationServices
import CryptoKit
import FirebaseAuth

// MARK: - OnboardingView

/// First-run intro carousel + sign-in panel + notification-priming step.
///
/// Three steps in sequence:
///   1. `.slides` — three horizontally-scrollable intro slides.
///   2. `.signIn` — sign-in panel ("One last thing / Save your streak.") with:
///        - Continue with Apple  → Apple Sign-In, then advances to `.notif`.
///        - Continue with email  → `onDone()` straight to the `AuthGateView` /
///          `LoginView` email form. No notif priming (user isn't authenticated
///          yet; they get it via Profile → Notifications after signing in).
///        - Maybe later          → anonymous sign-in, then advances to `.notif`.
///   3. `.notif` — notification priming (App Store 4.5.4 in-context prompt).
///        - "Turn on reminders" → enable master pref + request OS auth +
///          reconcile, then `onDone()`.
///        - "Not now"           → `onDone()` (master pref stays off).
///
/// First-run gate: reads/writes `UserDefaults.standard` key
/// `"oybc-onboarding-seen"` (Bool). Cleared by the "Replay onboarding"
/// developer tweak in ProfileView. Call `OnboardingView(authService:onDone:)`.
///
/// The `.notif` step is extracted into `NotifPrimingStepView` (pure props +
/// closures) so it can be snapshot-tested without Firebase/DB.
///
/// **Kit constraint**: does NOT modify `Views/Riso/*`. All Riso atoms —
/// `RisoButton`, `RisoPaperBackground`, `Color.riso*`, `Font.risoHead/Body`,
/// `Riso.*`, `.risoCard`, `.risoHardShadow`, `BlipPlaceholder` — are reused
/// as-is. New private helpers live below the main struct.
struct OnboardingView: View {

    // MARK: - Configuration

    /// Shared auth service. Used in the notif-priming step to write the
    /// `notificationsEnabled` pref and to obtain the current user's id for
    /// `NotificationService.reconcile`. Passed from `ContentView` so both
    /// `OnboardingView` and `AuthGateView` share the same instance.
    ///
    /// Optional so snapshot tests can construct `OnboardingView` without
    /// Firebase (they target the slides / sign-in panel only; the notif leaf
    /// `NotifPrimingStepView` is snapshot-tested independently).
    let authService: AuthService?

    /// Called when the user has finished onboarding (any path through the
    /// notif step — "Turn on reminders" or "Not now"). The caller persists the
    /// "seen" flag and swaps `OnboardingView` out of the view hierarchy.
    let onDone: () -> Void

    // MARK: - Step state

    /// Drives the three-step flow: slides → sign-in panel → notif priming.
    private enum OnboardingStep: Equatable {
        case slides
        case signIn
        case notif
    }

    @State private var step: OnboardingStep
    @State private var slideIndex: Int

    // MARK: - Sign-in state

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    // Apple Sign-In nonce — generated fresh per request.
    @State private var currentNonce: String?

    // MARK: - Init

    /// - Parameters:
    ///   - authService: The shared `AuthService` instance (from `ContentView`).
    ///     Pass `nil` only in snapshot tests that target the slides / sign-in
    ///     panel — those surfaces don't exercise the notif-priming action path.
    ///     `NotifPrimingStepView` is snapshot-tested independently.
    ///   - initialSlide: Slide index to start on (default 0). Snapshot use only.
    ///   - initialShowSignIn: Pre-show the sign-in panel. Snapshot use only.
    ///   - initialShowNotif: Pre-show the notif-priming step. Snapshot use only.
    ///   - onDone: Called when onboarding is fully dismissed.
    init(
        authService: AuthService? = nil,
        initialSlide: Int = 0,
        initialShowSignIn: Bool = false,
        initialShowNotif: Bool = false,
        onDone: @escaping () -> Void
    ) {
        self.authService = authService
        self.onDone = onDone
        let initialStep: OnboardingStep = initialShowNotif ? .notif
                                        : initialShowSignIn ? .signIn
                                        : .slides
        _step = State(initialValue: initialStep)
        _slideIndex = State(initialValue: initialSlide)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            switch step {
            case .slides:
                slideCarousel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .signIn:
                signInPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .notif:
                NotifPrimingStepView(
                    onTurnOn: { _Concurrency.Task { await handleTurnOnReminders() } },
                    onNotNow: onDone
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.30), value: step)
        .animation(.easeInOut(duration: 0.28), value: slideIndex)
    }

    // MARK: - Advance to notif step

    /// Moves to the notification-priming step. Called by all three sign-in
    /// paths (Apple, email, Maybe later) once their auth work is done.
    private func advanceToNotif() {
        withAnimation { step = .notif }
    }

    // MARK: - Notif-priming action

    /// "Turn on reminders" handler.
    ///
    /// 1. Sets `notificationsEnabled = true` in `UserPreferences` (if a user
    ///    row exists — skipped gracefully for the anonymous-before-DB-row path).
    /// 2. Calls `notificationService.requestAuthorization()` to show the OS
    ///    permission prompt.
    /// 3. Calls `notificationService.reconcile(userId:)` so the OS schedule
    ///    reflects the new pref immediately.
    /// 4. Calls `onDone()`.
    ///
    /// If there is no signed-in user (anonymous path before the DB row is
    /// ready), step 1 and 3 are skipped; the OS auth is still requested so
    /// the user gets a prompt and can grant permission even in a local session.
    private func handleTurnOnReminders() async {
        // If no authService (shouldn't happen in production — only in snapshot
        // tests that target this step directly via `initialShowNotif`), fall
        // through to just requesting OS auth, then calling onDone.
        guard let authService else {
            onDone()
            return
        }

        let notificationService = authService.notificationService
        let userId = authService.currentUser?.id

        // 1. Persist the master pref (best-effort; no crash if userId is nil).
        if let userId {
            do {
                _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                    var next = current
                    next.notificationsEnabled = true
                    return next
                }
            } catch {
                dlog("⚠️ OnboardingView: updateUserPreferences failed: \(error)")
            }
        }

        // 2. Show the OS permission prompt.
        await notificationService.requestAuthorization()

        // 3. Reconcile the OS schedule (skipped if no user row yet).
        if let userId {
            await notificationService.reconcile(userId: userId)
        }

        // 4. Finish onboarding.
        onDone()
    }

    // MARK: - Slide carousel (step: .slides)

    private var slideCarousel: some View {
        VStack(spacing: 0) {
            // Skip — top-right
            HStack {
                Spacer()
                skipButton
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
            }

            Spacer()

            // Art + copy (slides in on index change)
            slideContent
                .padding(.horizontal, Riso.gutter)

            Spacer()

            // Dots + action buttons
            slideFooter
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 32)
        }
    }

    // MARK: - Slide content

    @ViewBuilder
    private var slideContent: some View {
        let slide = OnboardingSlide.all[slideIndex]
        VStack(alignment: .leading, spacing: 14) {
            slideArt(for: slide.art)
                .padding(.bottom, 4)

            Text(slide.kicker)
                .risoKicker()

            Text(slide.title)
                .font(.risoHead(slide.art == .wordmark ? 64 : 34, .extraBold))
                .tracking(slide.art == .wordmark ? -1.92 : -1.02)
                .foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(slide.body)
                .font(.risoBody(15, .regular))
                .foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(slideIndex) // forces SwiftUI to re-create the view so the
                        // slide-in transition fires on index change.
    }

    // MARK: - Slide art

    @ViewBuilder
    private func slideArt(for kind: OnboardingArt) -> some View {
        switch kind {
        case .wordmark:
            OnboardingPosterGrid(highlightedSquares: [], ringSquares: [], isFull: true)
        case .lines:
            OnboardingPosterGrid(
                highlightedSquares: Set([5, 6, 7, 8, 9, 0, 12, 24, 18]),
                ringSquares: Set([5, 6, 7, 8, 9]),
                isFull: false
            )
        case .full:
            OnboardingPosterGrid(highlightedSquares: [], ringSquares: [], isFull: true)
        }
    }

    // MARK: - Slide footer (dots + Next/Get started / Back)

    private var slideFooter: some View {
        let isLast = slideIndex == OnboardingSlide.all.count - 1
        return VStack(spacing: 14) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<OnboardingSlide.all.count, id: \.self) { n in
                    Capsule()
                        .fill(Color.risoRed)
                        .frame(width: n == slideIndex ? 22 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.20), value: slideIndex)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 4)

            // Primary action
            RisoButton(
                title: isLast ? "Get started" : "Next",
                kind: .primary,
                fullWidth: true,
                large: true
            ) {
                if isLast {
                    withAnimation { step = .signIn }
                } else {
                    withAnimation { slideIndex += 1 }
                }
            }

            // Back (from slide 2 onwards)
            if slideIndex > 0 {
                SwiftUI.Button("Back") {
                    withAnimation { slideIndex -= 1 }
                }
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
            }
        }
    }

    // MARK: - Sign-in panel (step: .signIn)

    private var signInPanel: some View {
        VStack(spacing: 0) {
            // Skip — top-right (same position as on slides)
            HStack {
                Spacer()
                skipButton
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
            }

            Spacer()

            // Blip mascot + copy + buttons — centered
            VStack(spacing: 0) {
                BlipPlaceholder(size: 84, mood: .happy)
                    .padding(.bottom, 20)

                Text("One last thing")
                    .risoKicker()
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)

                Text("Save your streak.")
                    .font(.risoHead(28, .extraBold))
                    .tracking(-0.56)
                    .foregroundStyle(Color.risoInk)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)

                Text("Sign in so your boards sync across your devices and your GREENLOG history never resets.")
                    .font(.risoBody(14, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 28)

                if let errorMessage {
                    errorBanner(errorMessage)
                        .padding(.bottom, 14)
                }

                signInButtons
            }
            .padding(.horizontal, Riso.gutter)

            Spacer()
        }
    }

    // MARK: - Sign-in buttons

    private var signInButtons: some View {
        VStack(spacing: 12) {
            // Continue with Apple — ink-fill pill with Apple glyph
            appleSignInButton

            // Continue with email — keyline pill (neutral kind).
            // Goes straight to onDone() → AuthGateView's LoginView email form.
            // We deliberately do NOT show notif priming here: the user hasn't
            // authenticated yet (email sign-in happens in LoginView, after
            // onboarding), so priming would fire iOS's one-shot permission
            // prompt pre-auth and the master pref couldn't be persisted (no user
            // row). Email users get priming via Profile → Notifications instead.
            RisoButton(
                title: "Continue with email",
                kind: .neutral,
                systemImage: "message",
                fullWidth: true,
                large: true
            ) {
                onDone()
            }
            .disabled(isSubmitting)

            // Maybe later — muted text link (anonymous / local session).
            // Signs in anonymously so AppDatabase gets a user row, then
            // advances to the notif step.
            SwiftUI.Button("Maybe later") {
                _Concurrency.Task { await signInAnonymously() }
            }
            .font(.risoBody(14, .semibold))
            .foregroundStyle(Color.risoMuted)
            .disabled(isSubmitting)
        }
    }

    // MARK: - Apple Sign-In button

    /// Ink-filled pill matching the design: black background, Apple glyph +
    /// "Continue with Apple" in cream. Uses `SignInWithAppleButton` behind the
    /// scenes but styled to match the Riso system.
    private var appleSignInButton: some View {
        // SignInWithAppleButton must use the system style; we layer Riso
        // styling on top via a custom overlay approach. Because ASAuthorizationController
        // must use the system button, we use a ZStack with an overlay tap that
        // triggers the system presentation — but that requires the real
        // SignInWithAppleButton to receive touch. Instead we use the real button
        // styled `.black` at the correct height, which matches the ink-fill design.
        SignInWithAppleButton(
            .signIn,
            onRequest: { request in
                let nonce = randomNonceString()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = sha256(nonce)
            },
            onCompletion: { result in
                _Concurrency.Task { await handleAppleSignIn(result) }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .clipShape(Capsule())
        .disabled(isSubmitting)
    }

    // MARK: - Skip button

    private var skipButton: some View {
        SwiftUI.Button("Skip") {
            onDone()
        }
        .font(.risoBody(14, .semibold))
        .foregroundStyle(Color.risoMuted)
    }

    // MARK: - Error banner

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.risoRed)
            Text(message)
                .font(.risoBody(13, .regular))
                .foregroundStyle(Color.risoRed)
            Spacer()
        }
        .padding(12)
        .background(Color.risoRed.opacity(0.08), in: RoundedRectangle(cornerRadius: Riso.cardRadius))
    }

    // MARK: - Auth actions

    /// Signs in anonymously via Firebase so the user can use the app locally
    /// without an account. `AuthService`'s auth-state listener picks up the
    /// anonymous Firebase user and upserts a local GRDB `User` row. After
    /// sign-in succeeds, advances to the notif-priming step.
    ///
    /// TODO: Extract to `AuthService.signInAnonymously()` when that method is
    /// added to the service (currently AuthService has no anonymous path).
    /// The raw `Auth.auth().signInAnonymously()` call here is intentional and
    /// safe — the `AuthService` listener handles the rest exactly as it does
    /// for any other provider.
    private func signInAnonymously() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await Auth.auth().signInAnonymously()
            // Auth state listener in AuthService bootstraps the user row.
            // Advance to notif-priming (not straight to onDone).
            advanceToNotif()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        switch result {
        case .success(let authorization):
            guard let nonce = currentNonce else {
                errorMessage = "Apple sign-in failed: missing nonce."
                return
            }
            do {
                guard
                    let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let appleIDTokenData = appleIDCredential.identityToken,
                    let idTokenString = String(data: appleIDTokenData, encoding: .utf8)
                else {
                    errorMessage = "Apple sign-in failed: invalid credential."
                    return
                }

                let credential = OAuthProvider.appleCredential(
                    withIDToken: idTokenString,
                    rawNonce: nonce,
                    fullName: appleIDCredential.fullName
                )
                try await Auth.auth().signIn(with: credential)
                // Auth state listener handles the rest; advance to notif-priming.
                advanceToNotif()
            } catch {
                errorMessage = error.localizedDescription
            }

        case .failure(let error):
            // ASAuthorizationError.canceled (1001) is user-initiated; suppress it.
            let asError = error as? ASAuthorizationError
            if asError?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Nonce helpers (Apple Sign-In)

    /// Generates a cryptographically random nonce string of the given byte length.
    ///
    /// - Parameter length: Number of random bytes (default 32).
    /// - Returns: A URL-safe Base64-encoded nonce string.
    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        guard errorCode == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the SHA-256 hash of the given string as a lowercase hex string.
    ///
    /// - Parameter input: The raw nonce string.
    /// - Returns: The SHA-256 hex digest.
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Slide model

/// A single intro slide: kicker, title, body copy, and art kind.
private struct OnboardingSlide {
    let kicker: String
    let title: String
    let body: String
    let art: OnboardingArt

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            kicker: "Welcome to",
            title: "OYBC",
            body: "Own Your Bingo Card. Turn the goals you keep meaning to hit into a board you actually want to fill.",
            art: .wordmark
        ),
        OnboardingSlide(
            kicker: "The idea",
            title: "Fill squares,\nscore bingos.",
            body: "Every square is a habit or goal. Complete a row, column, or diagonal and it locks in as a bingo.",
            art: .lines
        ),
        OnboardingSlide(
            kicker: "The payoff",
            title: "Clear it for a\nGREENLOG.",
            body: "Fill the whole board and the page goes loud — confetti, streaks, the works. Then you start fresh.",
            art: .full
        ),
    ]
}

/// The art variant shown in the upper portion of each intro slide.
private enum OnboardingArt {
    /// Slide 1 — full red 5×5 poster grid (all done, FREE center cell black).
    case wordmark
    /// Slide 2 — a board with one lit row + one diagonal, gold rings on the bingo line.
    case lines
    /// Slide 3 — full red 5×5 poster grid (same as wordmark art).
    case full
}

// MARK: - Poster grid art

/// 5×5 mini board used as art in the onboarding slides. All squares shown as
/// red "done" cells; FREE center is ink-black with a gold star. Can highlight
/// a specific set of squares (row/diagonal) with gold outer rings for slide 2.
///
/// - Parameters:
///   - highlightedSquares: Indices of "lit" (done) squares. If empty and
///     `isFull` is true, all 25 squares are lit.
///   - ringSquares: Indices that get a gold outer ring (bingo-line indicator).
///   - isFull: When true, all non-FREE squares are rendered as done (red).
private struct OnboardingPosterGrid: View {
    let highlightedSquares: Set<Int>
    let ringSquares: Set<Int>
    let isFull: Bool

    private let cellSize: CGFloat = 46
    private let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<5, id: \.self) { col in
                        let index = row * 5 + col
                        cell(for: index)
                    }
                }
            }
        }
        // Fixed width so the grid doesn't stretch in wider layouts
        .frame(width: cellSize * 5 + gap * 4)
    }

    @ViewBuilder
    private func cell(for index: Int) -> some View {
        let isFree = index == 12
        let isLit = isFull ? !isFree : highlightedSquares.contains(index)
        let hasRing = ringSquares.contains(index)

        ZStack {
            if isFree {
                // FREE cell — ink black + gold star
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.risoInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.risoInk, lineWidth: 1.5)
                    )
                Image(systemName: "star.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.risoGold)
            } else if isLit {
                // Done cell — red fill + halftone
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.risoRed)
                    .risoHalftone(tile: 5, layerOpacity: 0.45)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.risoInk, lineWidth: 1.5)
                    )
            } else {
                // Empty cell — paper
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.risoPaper2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.risoInk, lineWidth: 1.5)
                    )
            }
        }
        .frame(width: cellSize, height: cellSize)
        // Gold ring for bingo-line cells
        .overlay {
            if hasRing {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.risoGold, lineWidth: 3)
                    .padding(-2)
            }
        }
    }
}

// MARK: - NotifPrimingStepView

/// Presentational leaf for the notification-priming step of onboarding.
///
/// Shown after a successful sign-in (any path) as the final onboarding screen.
/// App Store 4.5.4: this is the in-context priming displayed BEFORE the system
/// permission prompt. Copy is strictly functional — no marketing language.
///
/// Pure props + closures so it can be snapshot-tested without Firebase/DB:
///
/// ```swift
/// NotifPrimingStepView(onTurnOn: {}, onNotNow: {})
/// ```
///
/// - Parameters:
///   - onTurnOn: Called when "Turn on reminders" is tapped. The caller is
///     responsible for the pref write → `requestAuthorization` → `reconcile`
///     → `onDone` sequence.
///   - onNotNow:  Called when "Not now" is tapped. Should call `onDone()`
///     directly (master pref stays off, no permission prompt).
struct NotifPrimingStepView: View {

    let onTurnOn: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Art — sparse board tile with a bell badge (matches prototype §0)
            notifArt
                .padding(.bottom, 28)

            // Kicker + headline + body
            Text("Stay on streak")
                .risoKicker()
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text("A nudge, not a nag.")
                .font(.risoHead(28, .extraBold))
                .tracking(-0.56)
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text("We'll only ping you when a board's about to expire or a new streak window opens. Turn off anything in settings.")
                .font(.risoBody(14, .regular))
                .foregroundStyle(Color.risoMuted)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)

            // Buttons
            RisoButton(
                title: "Turn on reminders",
                kind: .primary,
                systemImage: "bell.badge",
                fullWidth: true,
                large: true,
                action: onTurnOn
            )
            .padding(.bottom, 16)

            SwiftUI.Button("Not now", action: onNotNow)
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)

            Spacer()
        }
        .padding(.horizontal, Riso.gutter)
    }

    // MARK: - Art

    /// Keyline mini-board (5×5, sparse fill) with a bell badge in the
    /// bottom-right corner. Matches the prototype `ob-notif-board` pattern:
    /// every third square is lit (red), FREE center is ink+star.
    private var notifArt: some View {
        ZStack(alignment: .bottomTrailing) {
            notifMiniBoard

            // Bell badge — ink keyline square with bell icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.risoInk)
                    .frame(width: 36, height: 36)
                Image(systemName: "bell.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.risoGold)
            }
            .offset(x: 8, y: 8) // slight overlap outside the grid
        }
    }

    /// Compact 5×5 grid for the notif step: every-third-square lit pattern
    /// (indices 0, 3, 6, 9, … excluding FREE at 12), FREE center ink+star.
    /// Uses a smaller cell size than the slide poster to fit alongside the badge.
    private var notifMiniBoard: some View {
        let cellSize: CGFloat = 38
        let gap: CGFloat = 5
        let litIndices: Set<Int> = Set(stride(from: 0, to: 25, by: 3).filter { $0 != 12 })

        return VStack(spacing: gap) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<5, id: \.self) { col in
                        let idx = row * 5 + col
                        notifCell(idx, cellSize: cellSize, litIndices: litIndices)
                    }
                }
            }
        }
        .frame(width: cellSize * 5 + gap * 4)
    }

    @ViewBuilder
    private func notifCell(
        _ index: Int, cellSize: CGFloat, litIndices: Set<Int>
    ) -> some View {
        let isFree = index == 12
        let isLit  = !isFree && litIndices.contains(index)

        ZStack {
            if isFree {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.risoInk)
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.risoGold)
            } else if isLit {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.risoRed)
                    .risoHalftone(tile: 5, layerOpacity: 0.45)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.risoInk, lineWidth: 1.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.risoPaper2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
            }
        }
        .frame(width: cellSize, height: cellSize)
    }
}

// MARK: - UserDefaults key

extension UserDefaults {
    /// Key used to persist whether the user has seen the onboarding flow.
    /// Set to `true` after any successful dismiss (sign-in or skip).
    /// Reset to `false` by the developer "Replay onboarding" tweak.
    static let onboardingSeenKey = "oybc-onboarding-seen"

    /// Returns `true` when the user has previously completed or skipped
    /// onboarding.
    static var hasSeenOnboarding: Bool {
        get { standard.bool(forKey: onboardingSeenKey) }
        set { standard.set(newValue, forKey: onboardingSeenKey) }
    }
}

// MARK: - Previews

#Preview("Slide 1 — Wordmark") {
    OnboardingView(onDone: {})
}

#Preview("Slide 3 — Get started") {
    OnboardingView(initialSlide: 2, onDone: {})
}

#Preview("Sign-in panel") {
    OnboardingView(initialShowSignIn: true, onDone: {})
}

#Preview("Notif priming") {
    ZStack {
        RisoPaperBackground()
        NotifPrimingStepView(onTurnOn: {}, onNotNow: {})
    }
}

#Preview("Notif priming — dark") {
    ZStack {
        RisoPaperBackground()
        NotifPrimingStepView(onTurnOn: {}, onNotNow: {})
    }
    .preferredColorScheme(.dark)
}
