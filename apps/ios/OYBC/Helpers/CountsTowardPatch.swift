import Foundation

/// The counter (and per-completion amount) a create flows into — set only by
/// Counter Detail's "+ New" preset; no task form exposes a picker.
struct CountsTowardSelection: Equatable {
    var counterId: String?
    var amount: Int = 1
}

struct CountsTowardPatch: Equatable {
    let counterId: String?
    let amount: Int?
}
