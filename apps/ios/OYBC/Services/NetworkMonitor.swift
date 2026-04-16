import Foundation
import Network

/// Lightweight NWPathMonitor wrapper that publishes connectivity state.
///
/// Injected as an `@EnvironmentObject` at the app root alongside
/// `AuthService` and `SyncService`. Views that need an online/offline
/// indicator can read `networkMonitor.isConnected`.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "oybc.NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // `_Concurrency.Task` to disambiguate from the OYBC `Task`
            // data model (Database/Models/Task.swift) — Swift picks the
            // local type by default in this file and fails compilation.
            _Concurrency.Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
