import Foundation
import Observation

@MainActor
@Observable
final class FileBrowserModel {
    private(set) var entries: [FileEntry] = []
    private(set) var visibleEntries: [FileEntry] = []
    private(set) var loading = false
    private(set) var arranging = false
    private(set) var errorMessage: String?
    private(set) var snapshotRevision = 0

    private let worker = FileListingWorker()
    private var loadID = UUID()
    private var displayID = UUID()
    private var sourcePath: String?
    private var sourceShowHidden = false

    func reload(path: String, showHidden: Bool, load: @Sendable (String, Bool) async throws -> [FileEntry]) async {
        let request = UUID()
        loadID = request
        loading = true
        errorMessage = nil
        if sourcePath != path || sourceShowHidden != showHidden {
            entries = []
            visibleEntries = []
            arranging = true
            snapshotRevision += 1
        }
        sourcePath = path
        sourceShowHidden = showHidden
        defer { if loadID == request { loading = false } }
        do {
            let result = try await load(path, showHidden)
            try Task.checkCancellation()
            guard loadID == request else { return }
            entries = result
            arranging = true
            snapshotRevision += 1
        } catch is CancellationError {
            // A cancelled request must not replace a newer folder or show an error.
        } catch {
            guard loadID == request, !Task.isCancelled else { return }
            entries = []
            visibleEntries = []
            errorMessage = error.localizedDescription
            arranging = false
            snapshotRevision += 1
        }
    }

    func updateVisible(search: String, options: FileListingOptions) async {
        let request = UUID(), revision = snapshotRevision
        displayID = request
        arranging = true
        defer { if displayID == request, snapshotRevision == revision { arranging = false } }
        do {
            let result = try await worker.apply(entries, search: search, options: options)
            try Task.checkCancellation()
            guard displayID == request, snapshotRevision == revision else { return }
            visibleEntries = result
        } catch is CancellationError {
        } catch {
            // The worker currently only throws cancellation errors.
        }
    }
}

struct BrowserLoadRequest: Equatable {
    let path: String
    let showHidden: Bool
    let revision: Int
}

struct BrowserDisplayRequest: Equatable {
    let revision: Int
    let search: String
    let options: FileListingOptions
}
