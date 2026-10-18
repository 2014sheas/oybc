import Foundation

// MARK: - BoardPlayViewModel + sync-triggered reloads

extension BoardPlayViewModel {

    /// Board-integrity PR-4 (Item 5): reload in response to a sync pull's post-apply signal.
    ///
    /// Skips while `editSaveInFlight` — `handleEditSave` runs its composed write and then calls
    /// `reload()` itself. While an interaction write is in flight (`isProcessing`) the reload is
    /// DEFERRED, not run: a snapshot read after the write committed but before this view model's
    /// own reload would carry the write while its optimistic delta is still pending, double-counting
    /// the number. `runDeferredSyncReload` runs it once the write has ended.
    ///
    /// Residual (not guarded here): a reload while the user is IN edit mode with unsaved staged
    /// changes (`editMode` is view-side `@State`). The staged draft is seeded once at edit entry,
    /// so a reload only refreshes the read-only grid behind the panel — no worse than a local tap's
    /// reload today.
    func handleSyncDidApplyChanges() {
        guard !editSaveInFlight else { return }
        if isProcessing { syncReloadDeferred = true; return }
        reload()
    }

    /// Runs the sync reload parked by `handleSyncDidApplyChanges` (called when `isProcessing` ends).
    func runDeferredSyncReload() {
        guard syncReloadDeferred else { return }
        syncReloadDeferred = false
        reload()
    }
}
