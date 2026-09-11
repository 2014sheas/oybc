import SwiftUI

/// EditProfileSheet — bottom sheet to update the user's display name
/// (§5b of the Riso redesign spec).
///
/// Opened from `RisoProfileAccountCard`'s name/✎ tap affordance in
/// `ProfileView`. On Save it calls `updateName(_:)`, which in production
/// wraps `AuthService.updateDisplayName(_:)` — updating Firebase Auth and
/// the local GRDB User row atomically (same path the old inline alert used).
///
/// Using a closure prop instead of `@EnvironmentObject AuthService` keeps
/// the view snapshot-testable without a live Firebase configuration.
///
/// Layout (over `Color.risoPaper`, inside a NavigationStack sheet):
/// 1. Navigation bar — "Edit profile" title, gold-pill "Done" (dismiss)
/// 2. Large initials avatar (92 px, `RisoInitialAvatar`) with hard shadow
/// 3. DISPLAY NAME label + `RisoTextField`
/// 4. EMAIL label + disabled text display + account-security hint
/// 5. Red "Save profile" full-width button (disabled when name empty)
struct EditProfileSheet: View {

    // MARK: - Inputs

    /// Current display name (pre-fills the text field).
    let displayName: String

    /// Current email (shown read-only).
    let email: String?

    /// Guest session (anonymous auth) — feeds the avatar's "G" fallback
    /// when no name is set. Defaulted so pre-existing call sites compile.
    var isGuest: Bool = false

    /// Async closure that persists the new display name. Typically wraps
    /// `AuthService.updateDisplayName(_:)` — separating the async persistence
    /// concern from the view makes it snapshot-testable without Firebase.
    ///
    /// - Parameter newName: The trimmed display name to persist.
    /// - Throws: Any error from the underlying auth/DB write.
    let updateName: (_ newName: String) async throws -> Void

    /// Called after `updateName` succeeds — dismiss the sheet here.
    let onSave: () -> Void

    /// Called when the user taps Done without saving.
    let onCancel: () -> Void

    // MARK: - Private state

    @State private var nameValue: String

    /// Tracks the async save in flight (disables the button while pending).
    @State private var isSaving = false

    /// Surface a localised error if the persistence write fails.
    @State private var saveError: String?

    // MARK: - Init

    /// - Parameters:
    ///   - displayName: Current display name to pre-fill.
    ///   - email: User's email (shown read-only; nil falls back to empty).
    ///   - isGuest: Anonymous session — the avatar falls back to "G" when
    ///              no name is set. Defaults false.
    ///   - updateName: Async closure that commits the new name (e.g. wraps
    ///                 `AuthService.updateDisplayName`).
    ///   - onSave: Closure called after a successful save; dismiss here.
    ///   - onCancel: Closure called on Done/Cancel without saving.
    init(
        displayName: String,
        email: String?,
        isGuest: Bool = false,
        updateName: @escaping (_ newName: String) async throws -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.displayName = displayName
        self.email = email
        self.isGuest = isGuest
        self.updateName = updateName
        self.onSave = onSave
        self.onCancel = onCancel
        _nameValue = State(initialValue: displayName)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    avatarPreview
                        .padding(.top, 20)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)

                    nameSection

                    emailSection
                        .padding(.top, 4)

                    if let saveError {
                        Text(saveError)
                            .font(.risoBody(12, .regular))
                            .foregroundStyle(Color.risoRed)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }

                    saveButton
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, Riso.gutter)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit profile")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Gold-pill Done button — dismisses without saving
                    RisoToolbarPill(title: "Done", action: onCancel)
                }
            }
        }
    }

    // MARK: - Avatar preview

    /// Large initials avatar (92 px) with a hard offset shadow — the
    /// separate paper2 ring circle went with the Blip. The initial tracks
    /// the live name field, so the preview reflects what a save produces.
    private var avatarPreview: some View {
        RisoInitialAvatar(
            initial: RisoInitialAvatar.initial(
                displayName: nameValue.isEmpty ? displayName : nameValue,
                email: email,
                isGuest: isGuest
            ),
            size: 92
        )
        .risoHardShadow(Riso.Shadow.small, radius: 46)
    }

    // MARK: - Display name field

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display name")
                .risoSectionLabel()
            RisoTextField(placeholder: "Your name", text: $nameValue)
        }
    }

    // MARK: - Email field (read-only)

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email")
                .risoSectionLabel()

            // Non-editable email display. Using Text (not a disabled TextField)
            // avoids the disabled tint inconsistency across iOS versions.
            Text(email ?? "")
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .background(Color.risoPaper)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk.opacity(0.35), lineWidth: Riso.Keyline.container)
                )

            Text("Change your email from Account security.")
                .font(.risoBody(11, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }

    // MARK: - Save button

    private var saveButton: some View {
        let trimmed = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSave = !trimmed.isEmpty && !isSaving
        return Button {
            guard canSave else { return }
            isSaving = true
            saveError = nil
            _Concurrency.Task {
                do {
                    try await updateName(trimmed)
                    await MainActor.run {
                        isSaving = false
                        onSave()
                    }
                } catch {
                    await MainActor.run {
                        isSaving = false
                        saveError = error.localizedDescription
                    }
                }
            }
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .tint(Color.risoPaper)
                } else {
                    Text("Save profile")
                        .font(.risoHead(17, .bold))
                        .foregroundStyle(Color.risoPaper)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .risoCard(fill: canSave ? Color.risoRed : Color.risoRed.opacity(0.45))
        }
        .buttonStyle(RisoButtonStyle(offset: canSave ? Riso.Shadow.button : 0, radius: Riso.cardRadius))
        .disabled(!canSave)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    EditProfileSheet(
        displayName: "OYBC User",
        email: "you@example.com",
        updateName: { _ in },
        onSave: {},
        onCancel: {}
    )
}
#endif
