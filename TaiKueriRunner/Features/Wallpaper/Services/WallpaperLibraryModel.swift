import Foundation
import Observation

struct WallpaperLibraryLoad: Sendable {
    let container: String
    let storePath: String?
    let snapshot: WallpaperLibrarySnapshot
}

@MainActor
@Observable
final class WallpaperLibraryModel {
    static let cacheLifetime: TimeInterval = 180
    private(set) var result: WallpaperLibraryLoad?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var revision = 0
    private(set) var processedCount = 0
    private(set) var hasCompleteSnapshot = false
    private var requestID = UUID()
    @ObservationIgnored private var activeTask: Task<WallpaperLibraryLoad, Error>?
    @ObservationIgnored private var cachedAt: Date?
    @ObservationIgnored private var cachedFileRevision: Int?
    @ObservationIgnored private var cacheGeneration = UUID()
    @ObservationIgnored private let now: @MainActor () -> Date

    init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    func refresh(fileRevision: Int, force: Bool = false, using loader: @escaping @MainActor (
        @escaping @Sendable (WallpaperLibraryLoad) async -> Void
    ) async throws -> WallpaperLibraryLoad) async {
        guard !Task.isCancelled else { return }
        if !force, result != nil, hasCompleteSnapshot, cachedFileRevision == fileRevision, let cachedAt {
            let age = now().timeIntervalSince(cachedAt)
            if age >= 0, age < Self.cacheLifetime { return }
        }
        await loadProgressively(cacheRevision: fileRevision, using: loader)
    }

    func invalidateCache() {
        cacheGeneration = UUID()
        cachedAt = nil
        cachedFileRevision = nil
    }

    func load(using loader: @escaping @MainActor () async throws -> WallpaperLibraryLoad) async {
        await loadProgressively { _ in try await loader() }
    }

    func loadProgressively(cacheRevision: Int? = nil, using loader: @escaping @MainActor (
        @escaping @Sendable (WallpaperLibraryLoad) async -> Void
    ) async throws -> WallpaperLibraryLoad) async {
        guard !Task.isCancelled else { return }
        activeTask?.cancel()
        let token = UUID()
        let cacheToken = cacheGeneration
        let preserveExisting = result != nil
        requestID = token
        loading = true
        error = nil
        processedCount = 0
        let task = Task(priority: .utility) { [weak self] in
            try await loader { [weak self] progress in
                await self?.receive(progress, token: token, preserveExisting: preserveExisting)
            }
        }
        activeTask = task
        defer {
            if requestID == token { loading = false; activeTask = nil }
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard requestID == token else { return }
            result = loaded
            processedCount = loaded.snapshot.items.count
            hasCompleteSnapshot = true
            if cacheGeneration == cacheToken {
                cachedAt = cacheRevision == nil ? nil : now()
                cachedFileRevision = cacheRevision
            }
            revision += 1
        } catch is CancellationError {
            // Keep displayed results, but never promote a partial scan to complete.
        } catch {
            guard requestID == token else { return }
            result = nil
            hasCompleteSnapshot = false
            invalidateCache()
            self.error = error.localizedDescription
        }
    }

    private func receive(_ progress: WallpaperLibraryLoad, token: UUID, preserveExisting: Bool) {
        guard requestID == token, activeTask?.isCancelled == false else { return }
        processedCount = progress.snapshot.items.count
        // A refresh should not replace a usable cached grid with 1, 8, 16... rows.
        if !preserveExisting || result?.container != progress.container {
            result = progress
            hasCompleteSnapshot = false
        }
    }

    func cancel(clearResult: Bool = true) {
        requestID = UUID()
        activeTask?.cancel()
        activeTask = nil
        loading = false
        if clearResult { result = nil; hasCompleteSnapshot = false; processedCount = 0; invalidateCache() }
    }
}
