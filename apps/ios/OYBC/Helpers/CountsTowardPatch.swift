import Foundation

/// The counter a create flows into — set only by
/// Counter Detail's "+ New" preset; no task form exposes a picker.
struct CountsTowardSelection: Equatable {
    var counterId: String?
}

/// A create's counts-toward write: the counter only — a contributor always
/// credits one (`countsTowardAmount` stays NULL, absent = 1).
struct CountsTowardPatch: Equatable {
    let counterId: String?
}
