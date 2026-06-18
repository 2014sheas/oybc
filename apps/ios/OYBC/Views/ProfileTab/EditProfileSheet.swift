import SwiftUI

/// EditProfileSheet — bottom sheet to update the user's display name and
/// Blip avatar mood (§5b of the Riso redesign spec).
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
/// 2. Large Blip avatar (84 px) with circular ink keyline + hard shadow
/// 3. BLIP MOOD section label + three keyline mood cards
/// 4. DISPLAY NAME label + `RisoTextField`
/// 5. EMAIL label + disabled text display + account-security hint
/// 6. Red "Save profile" full-width button (disabled when name empty)
///
/// The Blip mood selection is local state only for now — mood will be
/// stored in `UserPreferences` in a follow-up PR once the field is
/// added to the shared schema.
struct EditProfileSheet: View {

    // MARK: - Inputs

    /// Current display name (pre-fills the text field).
    let displayName: String

    /// Current email (shown read-only).
    let email: String?

    /// Current Blip mood as stored in preferences. Defaults to `.happy`.
    var initialMood: BlipPlaceholder.Mood = .happy

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
    @State private var selectedMood: BlipPlaceholder.Mood

    /// Tracks the async save in flight (disables the button while pending).
    @State private var isSaving = false

    /// Surface a localised error if the persistence write fails.
    @State private var saveError: String?

    // MARK: - Init

    /// - Parameters:
    ///   - displayName: Current display name to pre-fill.
    ///   - email: User's email (shown read-only; nil falls back to empty).
    ///   - initialMood: Current Blip avatar mood. Defaults to `.happy`.
    ///   - updateName: Async closure that commits the new name (e.g. wraps
    ///                 `AuthService.updateDisplayName`).
    ///   - onSave: Closure called after a successful save; dismiss here.
    ///   - onCancel: Closure called on Done/Cancel without saving.
    init(
        displayName: String,
        email: String?,
        initialMood: BlipPlaceholder.Mood = .happy,
        updateName: @escaping (_ newName: String) async throws -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.displayName = displayName
        self.email = email
        self.initialMood = initialMood
        self.updateName = updateName
        self.onSave = onSave
        self.onCancel = onCancel
        _nameValue = State(initialValue: displayName)
        _selectedMood = State(initialValue: initialMood)
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

                    moodSection

                    nameSection
                        .padding(.top, 14)

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
                    Button(action: onCancel) {
                        Text("Done")
                            .font(.risoHead(13, .extraBold))
                            .foregroundStyle(Color.risoInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.risoGold))
                            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    }
                    .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
                }
            }
        }
    }

    // MARK: - Avatar preview

    /// Large circular Blip at 84 px with an ink keyline ring and a hard
    /// offset shadow — matching the spec's "keyline + hard shadow" avatar.
    private var avatarPreview: some View {
        ZStack {
            // Hard offset shadow layer (drawn behind)
            Circle()
                .fill(Color.risoInk)
                .frame(width: 92, height: 92)
                .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)

            // Paper2 background + ink keyline ring
            Circle()
                .fill(Color.risoPaper2)
                .frame(width: 92, height: 92)
                .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))

            BlipPlaceholder(size: 84, mood: selectedMood)
        }
        .frame(width: 92, height: 92)
    }

    // MARK: - Blip mood picker

    /// Three keyline card buttons — Happy / Cheer / Calm.
    /// Selected card gets a gold fill + hard shadow.
    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blip mood")
                .risoSectionLabel()

            HStack(spacing: 8) {
                ForEach(BlipPlaceholder.Mood.allCases, id: \.self) { mood in
                    moodCard(mood)
                }
            }
        }
    }

    @ViewBuilder
    private func moodCard(_ mood: BlipPlaceholder.Mood) -> some View {
        let isSelected = selectedMood == mood
        Button {
            selectedMood = mood
        } label: {
            VStack(spacing: 8) {
                BlipPlaceholder(size: 40, mood: mood)
                Text(mood.label)
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(isSelected ? Color.risoInk : Color.risoMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .risoCard(fill: isSelected ? Color.risoGold : Color.risoPaper2)
        }
        .buttonStyle(RisoButtonStyle(offset: isSelected ? Riso.Shadow.small : 0, radius: Riso.cardRadius))
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

// MARK: - BlipPlaceholder.Mood helpers

extension BlipPlaceholder.Mood: CaseIterable {
    // `internal` to match `BlipPlaceholder` (a `public` witness on an internal
    // type is misleading — it can't actually widen access).
    static var allCases: [BlipPlaceholder.Mood] { [.happy, .cheer, .calm] }

    /// Display label for the mood picker card.
    var label: String {
        switch self {
        case .happy: return "Happy"
        case .cheer: return "Cheer"
        case .calm: return "Calm"
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    EditProfileSheet(
        displayName: "OYBC User",
        email: "you@example.com",
        initialMood: .happy,
        updateName: { _ in },
        onSave: {},
        onCancel: {}
    )
}
#endif
