import Foundation

/// A field of the counter sheet that can show a validation error.
enum CounterSheetField: Hashable {
    case noun, verb
}

/// The pure model behind the counter sheet's leaf (`NewCounterSheetContentView`):
/// every typed field, the live dimmed defaults they derive, and the
/// validation. Create and edit share it. Web twin: the sheet's state in
/// `CreateCounterSheet.tsx` + `counterEditModel.ts`.
struct CounterSheetForm: Equatable {
    var verb = ""
    var noun = ""
    var name = ""
    var singular = ""
    var plural = ""
    var startText = ""
    var kind: CountKind = .discrete
    /// Typed default-goal text per timeframe ("" / absent = unset).
    var goalTexts: [CounterSettings.GoalTimeframe: String] = [:]

    /// The edit sheet's form, seeded from the counter's root.
    ///
    /// - Parameter root: The counter's root task.
    /// - Returns: The prefilled form.
    static func seed(root: Task) -> CounterSheetForm {
        let seed = CounterEditModel.seed(root)
        return CounterSheetForm(
            verb: seed.verb, noun: seed.noun,
            name: seed.settings.name, singular: seed.settings.singular, plural: seed.settings.plural,
            kind: seed.kind,
            goalTexts: DefaultsRowModel.texts(from: seed.settings.goals, kind: seed.kind)
        )
    }

    var trimmedVerb: String { verb.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedNoun: String { noun.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The goals typed into the Defaults row (positive, parseable).
    var enteredGoals: [CounterSettings.GoalTimeframe: CountValue] {
        DefaultsRowModel.goals(from: goalTexts, kind: kind)
    }

    /// True when a non-blank Defaults entry does not parse as a positive goal.
    var goalsInvalid: Bool { !DefaultsRowModel.invalid(goalTexts, kind: kind).isEmpty }

    /// The optional fields as typed.
    var settingsDraft: CounterSettings.Draft {
        .init(name: name, singular: singular, plural: plural, goals: enteredGoals)
    }

    /// The sheet's LIVE noun / verb / kind (never the stored root).
    var context: CounterSettings.Fields {
        .init(action: trimmedVerb, unit: trimmedNoun, countKind: kind)
    }

    /// The dimmed defaults the unset fields show.
    var defaults: CounterSettings.Defaults { CounterSettings.defaults(context, draft: settingsDraft) }

    /// A template default as the field shows it: nothing until there is a
    /// verb and (but for Duration) a noun to build it from.
    ///
    /// - Parameter template: A default template from ``defaults``.
    /// - Returns: The template, or "" when its inputs are incomplete.
    func shownTemplateDefault(_ template: String) -> String {
        guard !trimmedVerb.isEmpty, !trimmedNoun.isEmpty || kind == .duration else { return "" }
        return template.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stored settings this form resolves to.
    var storedSettings: CounterSettings.Stored { CounterSettings.stored(fromDraft: settingsDraft, context: context) }

    /// The edit model's draft.
    var editDraft: CounterEditModel.Draft {
        .init(verb: verb, noun: noun, kind: kind, settings: settingsDraft)
    }

    /// Whether the noun is required: always on create; on edit a Duration
    /// counter's noun stays optional (an existing root may have no unit).
    func nounRequired(isEditing: Bool) -> Bool { !isEditing || countKindNeedsUnit(kind) }

    /// Whether the required fields are filled (noun + verb).
    func requiredFilled(isEditing: Bool) -> Bool {
        !trimmedVerb.isEmpty && (!trimmedNoun.isEmpty || !nounRequired(isEditing: isEditing))
    }

    /// The inline error under `field`, if it should show: the field is
    /// required, empty, and has been touched.
    ///
    /// - Parameters:
    ///   - field: The field.
    ///   - touched: The fields edited-then-emptied or blurred while empty.
    ///   - isEditing: Edit mode.
    /// - Returns: The error copy, or nil.
    func error(for field: CounterSheetField, touched: Set<CounterSheetField>, isEditing: Bool) -> String? {
        guard touched.contains(field) else { return nil }
        switch field {
        case .noun:
            return nounRequired(isEditing: isEditing) && trimmedNoun.isEmpty ? "Enter what you're counting." : nil
        case .verb:
            return trimmedVerb.isEmpty ? "Enter a verb." : nil
        }
    }
}
