import SwiftUI
import AuthenticationServices
import CryptoKit
import FirebaseAuth

// MARK: - OnboardingView

/// First-run intro carousel + sign-in panel.
///
/// Shows three horizontally-scrollable intro slides (slide-in transition,
/// no opacity gate so reduced-motion always sees content), then a sign-in
/// panel ("One last thing / Save your streak.") with:
///   - Continue with Apple  → real Sign in with Apple via `AuthService`.
///   - Continue with email  → dismisses onboarding and falls through to
///     the existing `AuthGateView` / `LoginView` email form.
///   - Maybe later          → signs in anonymously via Firebase
///     (`Auth.auth().signInAnonymously()`). TODO: wire to a dedicated
///     `AuthService.signInAnonymously()` method when added to the service;
///     for now uses the raw Firebase call so the existing `AuthGateView`
///     auth-state handler picks up the result.
///
/// First-run gate: reads/writes `UserDefaults.standard` key
/// `"oybc-onboarding-seen"` (Bool). Cleared by the "Replay onboarding"
/// developer tweak in ProfileView when present. Call `OnboardingView(onDone:)`
/// and wrap the result around `ContentView` in `OYBCApp`; once `onDone` fires,
/// swap back to `ContentView`.
///
/// **Kit constraint**: does NOT modify `Views/Riso/*`. All Riso atoms —
/// `RisoButton`, `RisoPaperBackground`, `Color.riso*`, `Font.risoHead/Body`,
/// `Riso.*`, `.risoCard`, `.risoHardShadow`, `BlipPlaceholder` — are reused
/// as-is. New private helpers live below the main struct.
struct OnboardingView: View {

    // MARK: - Configuration

    /// Called when the user has finished onboarding (any of the three sign-in
    /// paths, or Skip). The caller should persist the "seen" flag and swap
    /// `OnboardingView` out of the view hierarchy.
    let onDone: () -> Void

    // MARK: - Slide state

    /// Index of the currently-visible intro slide (0-based). Clamped to
    /// `0..<OnboardingSlide.all.count`.
    var currentSlideIndex: Int = 0

    /// Whether the sign-in panel is shown (replaces the slide carousel after
    /// tapping "Get started" on the last slide).
    var showSignIn: Bool = false

    // MARK: - Error state (sign-in panel)

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    // Apple Sign-In nonce — generated fresh per request.
    @State private var currentNonce: String?

    /// Mutable copies for animation. The initialiser injects seed values so
    /// snapshot tests can pin a specific slide or show the sign-in panel
    /// without any @State magic.
    @State private var slideIndex: Int
    @State private var isSignIn: Bool

    // MARK: - Init

    /// - Parameters:
    ///   - initialSlide: The slide index to start on (default 0). Used by
    ///     snapshot tests to record a specific slide.
    ///   - initialShowSignIn: Pre-show the sign-in panel (default false). Used
    ///     by snapshot tests.
    ///   - onDone: Called when onboarding is dismissed via any path.
    init(
        initialSlide: Int = 0,
        initialShowSignIn: Bool = false,
        onDone: @escaping () -> Void
    ) {
        self.onDone = onDone
        self.currentSlideIndex = initialSlide
        self.showSignIn = initialShowSignIn
        _slideIndex = State(initialValue: initialSlide)
        _isSignIn = State(initialValue: initialShowSignIn)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            if isSignIn {
                signInPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                slideCarousel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.30), value: isSignIn)
        .animation(.easeInOut(duration: 0.28), value: slideIndex)
    }

    // MARK: - Slide carousel

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
                    withAnimation { isSignIn = true }
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

    // MARK: - Sign-in panel

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

            // Continue with email — keyline pill (neutral kind)
            RisoButton(
                title: "Continue with email",
                kind: .neutral,
                systemImage: "message",
                fullWidth: true,
                large: true
            ) {
                // Dismiss onboarding and let AuthGateView's LoginView handle
                // the email flow. The user will see the existing email form.
                onDone()
            }
            .disabled(isSubmitting)

            // Maybe later — muted text link (anonymous / local session)
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
    /// without an account. The existing `AuthService` auth-state listener picks
    /// up the anonymous Firebase user and upserts a local GRDB `User` row.
    ///
    /// TODO: Extract to `AuthService.signInAnonymously()` when that method is
    /// added to the service (currently AuthService has no anonymous path).
    /// The raw `Auth.auth().signInAnonymously()` call here is intentional and
    /// safe — `AuthService`'s `addStateDidChangeListener` handler will receive
    /// the result and bootstrap the local user row exactly as it does for any
    /// other provider.
    private func signInAnonymously() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await Auth.auth().signInAnonymously()
            // Auth state listener in AuthService picks up the signed-in user.
            // Dismiss onboarding — AuthGateView will now render MainTabView.
            onDone()
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
                // Auth state listener handles the rest; dismiss onboarding.
                onDone()
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
    OnboardingView(initialSlide: 0) {}
}

#Preview("Slide 3 — Get started") {
    OnboardingView(initialSlide: 2) {}
}

#Preview("Sign-in panel") {
    OnboardingView(initialShowSignIn: true) {}
}
