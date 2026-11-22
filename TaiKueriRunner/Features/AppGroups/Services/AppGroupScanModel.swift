import Foundation
import Observation

@MainActor
@Observable
final class AppGroupScanModel {
    private(set) var snapshot: AppGroupScanSnapshot?
    private(set) var loading = false
    private(set) var complete = false
    private(set) var interrupted = false
    private(set) var error: String?
    private var requestID = UUID()

    func load(forceRefresh: Bool = false,
              using loader: (@escaping @Sendable (AppGroupScanSnapshot) async -> Void) async throws -> AppGroupScanSnapshot) async {
        guard !Task.isCancelled else { return }
        // A completed result is reused unless the user explicitly refreshes.
        // Views normally avoid this call too; keeping the check here prevents
        // accidental re-scans after a view is recreated.
        if !forceRefresh, complete, snapshot != nil { return }
        let token = UUID()
        requestID = token
        loading = true; complete = false; interrupted = false; error = nil
        // Keep the previous list visible while refreshing. Only a reader that
        // actually performs I/O publishes partial snapshots.
        defer { if requestID == token { loading = false } }
        do {
            let result = try await loader { partial in await self.receive(partial, token: token) }
            try Task.checkCancellation()
            guard requestID == token else { return }
            snapshot = result
            complete = true
        } catch is CancellationError {
            if requestID == token { interrupted = snapshot != nil }
        }
        catch {
            guard requestID == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        if loading { interrupted = true }
        requestID = UUID()
        loading = false
    }

    /// Clears a completed result after an explicit refresh of the application
    /// list invalidated the shared scanner cache.
    func invalidate() {
        requestID = UUID()
        snapshot = nil
        loading = false
        complete = false
        interrupted = false
        error = nil
    }

    private func receive(_ partial: AppGroupScanSnapshot, token: UUID) {
        guard requestID == token, loading, !Task.isCancelled else { return }
        snapshot = partial
    }
}
