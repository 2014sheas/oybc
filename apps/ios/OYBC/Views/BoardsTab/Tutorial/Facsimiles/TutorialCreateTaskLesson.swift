import SwiftUI

// MARK: - Lesson 1 · Create a task

/// The lesson 1 facsimiles: the Tasks tab (`TutorialTasksFacsimile`) and the
/// New task sheet (`TutorialNewTaskSheetFacsimile`), fed by
/// `TutorialCreateTaskState`. The library list is a fixture that mirrors only
/// the writes made in this lesson, never the user's own library. The three
/// tells sit over these screens with nothing lifted (the stage draws them).
struct TutorialCreateTaskLesson: View {
    let state: TutorialCreateTaskState
    let step: Int
    let perform: (TutorialEvent) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            TutorialTasksFacsimile(state: state, step: step, perform: perform)
            if state.sheetOpen {
                TutorialBehindSheetDim()
                TutorialNewTaskSheetFacsimile(state: state, step: step, perform: perform)
            }
        }
    }
}

// MARK: - Tasks tab facsimile

/// The Tasks header, segment, search, chips and the (fixture) library list,
/// all inert except the gold +. Shows the two tasks once the lesson wrote them.
struct TutorialTasksFacsimile: View {
    let state: TutorialCreateTaskState
    let step: Int
    let perform: (TutorialEvent) -> Void

    /// The fixture rows: what this lesson wrote, counting task first (newest).
    private var rows: [(title: String, kind: RisoTaskKind, sub: String?)] {
        var rows: [(String, RisoTaskKind, String?)] = []
        if let counting = state.countingTitle, let goal = state.goalValue {
            rows.append((counting, .counting, "goal \(goal) \(state.trimmedUnit)"))
        }
        if let added = state.addedTitle { rows.append((added, .normal, nil)) }
        return rows
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RisoPaperBackground()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your library").risoKicker()
                        Text("Tasks").risoH1()
                    }
                    .tutorialInert()
                    Spacer(minLength: 12)
                    RisoIconButton(systemImage: "plus") { perform(.plusTapped) }
                        .tutorialWired(.tasksPlus)
                        .accessibilityLabel("New task")
                }
                .padding(.top, 16)

                HStack {
                    HStack(spacing: 4) {
                        pill("Library", on: true)
                        pill("Pools · 0", on: false)
                    }
                    .padding(4)
                    .background(Capsule().fill(Color.risoPaper))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
                .tutorialInert()

                VStack(alignment: .leading, spacing: 10) {
                    TutorialSearchFieldFacsimile(placeholder: "Search tasks")
                    HStack(spacing: 7) {
                        RisoChip(title: "All", isOn: true) {}
                        RisoChip(title: "Normal") {}
                        RisoChip(title: "Counting") {}
                        RisoChip(title: "Compound") {}
                    }
                    .tutorialInert()
                }
                .padding(.top, 12)

                VStack(spacing: 8) {
                    if rows.isEmpty {
                        Text("No tasks yet.")
                            .font(.risoBody(15, .semibold))
                            .foregroundStyle(Color.risoInk)
                            .padding(16)
                            .frame(maxWidth: .infinity)
                            .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper2)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            libraryRow(row.title, kind: row.kind, sub: row.sub)
                        }
                    }
                }
                .padding(.top, 12)
                .tutorialInert()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Riso.gutter)

            TutorialTabBarFacsimile(active: .tasks)
                .padding(.bottom, 30)
        }
    }

    private func pill(_ label: String, on: Bool) -> some View {
        Text(label)
            .font(.risoHead(11, .bold))
            .foregroundStyle(on ? Color.risoPaper : Color.risoMuted)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(Capsule().fill(on ? Color.risoInk : Color.clear))
    }

    private func libraryRow(_ title: String, kind: RisoTaskKind, sub: String?) -> some View {
        HStack(spacing: 10) {
            RisoTypeBadge(kind: kind, style: .letterSquare)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.risoBody(15, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
                if let sub {
                    Text(sub).font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 2) {
                    Text("0").font(.risoBody(13, .bold)).foregroundStyle(Color.risoInk)
                    Text(" bds").font(.risoBody(13, .regular)).foregroundStyle(Color.risoMuted)
                }
                Text("0 active").font(.risoBody(11, .semibold)).foregroundStyle(Color.risoGreen)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
    }
}

// MARK: - New task sheet facsimile

/// The New task sheet: Cancel / "New task" / Done inert; the quick-add row, the
/// Special type button and the Counting fields wired one step at a time. The
/// Compound and Achievement chips carry a lock (their lessons are Pro); Kind
/// shows Discrete, inert.
struct TutorialNewTaskSheetFacsimile: View {
    let state: TutorialCreateTaskState
    let step: Int
    let perform: (TutorialEvent) -> Void

    @FocusState private var focus: TutorialField?

    private typealias Step = TutorialCreateTaskState.Step

    var body: some View {
        TutorialSheetPanel(top: 12, grabber: false) {
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            quickAdd
                            special
                        }
                        .padding(16)
                        .padding(.bottom, 40)
                    }
                    .onChange(of: step) { _, now in
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(scrollTarget(now), anchor: .center) }
                    }
                }
            }
        }
        // Focus set after layout (a focus written during appear is often dropped).
        .onAppear { DispatchQueue.main.async { focus = focusTarget(step) } }
        .onChange(of: step) { _, now in DispatchQueue.main.async { focus = focusTarget(now) } }
        .toolbar {
            // The number pad has no Return, so the keyboard carries the lit
            // field's action; on the other fields it mirrors their Return.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                RisoButton(title: focus == .quickAdd ? "Add" : "Next", kind: .gold, small: true) { keyboardAction() }
                    .padding(.vertical, 4)
            }
        }
    }

    /// The keyboard toolbar's button: the focused field's Return.
    private func keyboardAction() {
        switch focus {
        case .quickAdd: perform(.quickAddSubmitted)
        case .verb: perform(.fieldSubmitted(.verb))
        case .goal: perform(.fieldSubmitted(.goal))
        case .unit: perform(.fieldSubmitted(.unit))
        case .wizardQuickAdd, nil: break
        }
    }

    /// Which field holds the keyboard at a step.
    private func focusTarget(_ step: Int) -> TutorialField? {
        switch step {
        case Step.quickAdd: return .quickAdd
        case Step.verb: return .verb
        case Step.goal: return .goal
        case Step.unit: return .unit
        default: return nil
        }
    }

    private func scrollTarget(_ step: Int) -> String {
        switch step {
        case Step.tellKinds, Step.quickAdd, Step.special: return "quick"
        case Step.submit: return "submit"
        default: return "fields"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Cancel")
                .font(.risoBody(15, .semibold))
                .foregroundStyle(Color.risoMuted)
            Spacer()
            Text("New task")
                .font(.risoHead(17, .extraBold))
                .foregroundStyle(Color.risoInk)
            Spacer()
            RisoToolbarPill(title: "Done") {}
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(height: 50)
        .tutorialInert()
    }

    // MARK: Quick add

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick add").risoSectionLabel().tutorialInert()
            HStack(spacing: 8) {
                TextField("e.g. Meditate 10 min", text: binding(.quickAdd, state.quickText))
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoInk)
                    .tint(Color.risoBlue)
                    .focused($focus, equals: .quickAdd)
                    .submitLabel(.done)
                    .onSubmit { perform(.quickAddSubmitted) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.risoPaper)
                    .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                    .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                RisoButton(title: "Add", kind: .primary) { perform(.quickAddSubmitted) }
                    .opacity(state.trimmedQuick.isEmpty ? 0.45 : 1)
                    .disabled(state.trimmedQuick.isEmpty)
            }
            .padding(12)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
            .tutorialWired(.quickAddRow)
            .id("quick")

            if let added = state.addedTitle {
                HStack(spacing: 10) {
                    RisoTypeBadge(kind: .normal, style: .letterSquare)
                    Text(added).font(.risoBody(15, .semibold)).foregroundStyle(Color.risoInk).lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                        Text("In your library").font(.risoBody(11, .bold))
                    }
                    .foregroundStyle(Color.risoGreen)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper2)
                .tutorialInert()
            }
        }
    }

    // MARK: Special type

    @ViewBuilder
    private var special: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Special type").risoSectionLabel().tutorialInert()
            if state.panelOpen {
                countingPanel
            } else {
                Button { perform(.specialTapped) } label: {
                    HStack(spacing: 8) {
                        Text("＋").font(.risoHead(15, .extraBold)).foregroundStyle(Color.risoBlue)
                        Text("Counting · Compound · Achievement").font(.risoHead(13, .bold)).foregroundStyle(Color.risoInk)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4]))
                            .foregroundStyle(Color.risoInk)
                    )
                }
                .buttonStyle(.plain)
                .tutorialWired(.specialTypeButton)
            }
        }
    }

    private var countingPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Special task").risoSectionLabel()
                Spacer()
                TutorialCloseGlyph()
            }
            .tutorialInert()

            HStack(spacing: 6) {
                TutorialSegment(label: "Counting", isOn: true, fontSize: 12)
                TutorialLockedSegment(label: "Compound", fontSize: 12, showsLock: true)
                TutorialLockedSegment(label: "Achievement", fontSize: 12, showsLock: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                field(label: "Verb", required: true) {
                    TextField("Do", text: binding(.verb, state.verb))
                        .focused($focus, equals: .verb)
                        .submitLabel(.next)
                        .onSubmit { perform(.fieldSubmitted(.verb)) }
                        .textFieldStyle(TutorialFieldStyle())
                }
                .tutorialWired(.verbField)

                field(label: "Kind") {
                    HStack(spacing: 6) {
                        TutorialSegment(label: "Discrete", isOn: true)
                        TutorialSegment(label: "Continuous")
                        TutorialSegment(label: "Duration")
                    }
                }
                .tutorialInert()

                HStack(alignment: .top, spacing: 10) {
                    field(label: "Goal", required: true) {
                        TextField("100", text: binding(.goal, state.goal))
                            .keyboardType(.numberPad)
                            .focused($focus, equals: .goal)
                            .textFieldStyle(TutorialFieldStyle())
                    }
                    .tutorialWired(.goalField)
                    field(label: "Counting", required: true) {
                        TextField("push-ups", text: binding(.unit, state.unit))
                            .focused($focus, equals: .unit)
                            .submitLabel(.done)
                            .onSubmit { perform(.fieldSubmitted(.unit)) }
                            .textFieldStyle(TutorialFieldStyle())
                    }
                    .tutorialWired(.unitField)
                }

                if let title = state.derivedTitle {
                    HStack(spacing: 0) {
                        Text("Title: ").font(.risoBody(11, .semibold)).foregroundStyle(Color.risoMuted)
                        Text(title).font(.risoBody(11, .extraBold)).foregroundStyle(Color.risoInk)
                    }
                    .tutorialInert()
                }
            }
            .id("fields")

            RisoButton(title: "Add to library", kind: .blue, fullWidth: true) { perform(.addToLibraryTapped) }
                .opacity(state.canAddToLibrary ? 1 : 0.45)
                .disabled(!state.canAddToLibrary)
                .tutorialWired(.addToLibrary)
                .id("submit")
        }
        .padding(12)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    private func field<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text(label).risoSectionLabel()
                if required { Text("*").font(.risoBody(11, .bold)).foregroundStyle(Color.risoRed) }
            }
            .accessibilityHidden(true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(_ field: TutorialField, _ value: String) -> Binding<String> {
        Binding(get: { value }, set: { perform(.typed(field, $0)) })
    }
}

/// The kit's field look (`RisoTextField`'s style) for a facsimile `TextField`
/// that needs focus and submit handling of its own.
struct TutorialFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.risoHead(14, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}
