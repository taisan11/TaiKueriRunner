import Foundation
import Observation

@MainActor
@Observable
final class ApplicationCatalogModel {
    private(set) var snapshot: ApplicationCatalogSnapshot?
    private(set) var loading = false
    private(set) var status = ""
    private(set) var errorMessage: String?
    private var requestID = UUID()

    func load(using loader: (@escaping @Sendable (String) async -> Void) async throws -> ApplicationCatalogSnapshot) async {
        let request = UUID()
        requestID = request
        loading = true
        snapshot = nil
        errorMessage = nil
        status = L("準備中…")
        defer { if requestID == request { loading = false } }
        do {
            let result = try await loader { message in
                await self.updateStatus(message, request: request)
            }
            try Task.checkCancellation()
            guard requestID == request else { return }
            snapshot = result
            status = L("読み込み完了")
        } catch is CancellationError {
            if requestID == request { status = L("中止しました。") }
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            status = L("読み込めませんでした。")
        }
    }

    private func updateStatus(_ message: String, request: UUID) {
        if requestID == request, !Task.isCancelled { status = message }
    }

    /// Takes over a snapshot that another middle-layer screen read explicitly,
    /// so the Applications screen already shows the refreshed DB.
    func adopt(_ snapshot: ApplicationCatalogSnapshot) {
        requestID = UUID()
        self.snapshot = snapshot
        loading = false
        status = L("読み込み完了")
        errorMessage = nil
    }
}
