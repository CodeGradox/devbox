import Foundation
import Observation

/// A project operation owns its task and revision independently of tab visibility.
/// Canceling invalidates late results even when a backend ignores cancellation.
@MainActor @Observable
final class ProjectLoadingState {
    private(set) var isLoading = false
    var error: String?
    var progress = ""
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private(set) var revision = UUID()

    @discardableResult
    func begin(_ progress: String = "") -> UUID {
        cancel()
        error = nil
        self.progress = progress
        isLoading = true
        return revision
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        progress = ""
    }

    func accepts(_ token: UUID) -> Bool { revision == token }

    func finish(_ token: UUID) {
        guard accepts(token) else { return }
        isLoading = false
        progress = ""
        task = nil
    }
}
