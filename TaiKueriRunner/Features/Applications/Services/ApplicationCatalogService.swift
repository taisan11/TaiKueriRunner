import Foundation

protocol ApplicationCatalogAccess: Actor {
    func readLaunchServicesCatalog(path: String, group: String) async throws -> ParsedApplicationCatalog
}

actor ApplicationCatalogService {
    private let files: any ApplicationCatalogAccess
    private let finder: LaunchServicesStoreFinder
    private var lastCandidateError: String?
    private struct CacheKey: Equatable, Sendable {
        let group: String
    }
    private var cache = SessionReadCache<CacheKey, ApplicationCatalogSnapshot>()

    init(files: any ApplicationCatalogAccess, finder: LaunchServicesStoreFinder = LaunchServicesStoreFinder()) {
        self.files = files
        self.finder = finder
    }

    /// Returns the session cache when available. A read only happens when the
    /// cache is empty (first use), when a fresh DB search was requested, or
    /// when the user explicitly refreshes (`forceRefresh`).
    func load(cachedPath: String?, group: String, freshSearch: Bool,
              forceRefresh: Bool = false,
              progress: @escaping @Sendable (String) async -> Void) async throws -> ApplicationCatalogSnapshot {
        try Task.checkCancellation()
        let key = CacheKey(group: group)
        if !freshSearch, !forceRefresh, let snapshot = cache.value(for: key) { return snapshot }
        let token = cache.invalidate()
        let snapshot = try await read(cachedPath: cachedPath, group: group, freshSearch: freshSearch, progress: progress)
        try Task.checkCancellation()
        cache.store(snapshot, for: key, token: token)
        return snapshot
    }

    func invalidateCache() { cache.invalidate() }

    private func read(cachedPath: String?, group: String, freshSearch: Bool,
                      progress: @escaping @Sendable (String) async -> Void) async throws -> ApplicationCatalogSnapshot {
        lastCandidateError = nil
        if !freshSearch, let path = cachedPath, LaunchServicesPaths.daemonContainer(forStore: path) != nil {
            await progress(L("前回のLaunchServices DBを確認中…"))
            do { return try await readDeviceCatalog(path: path, group: group) }
            catch is CancellationError { throw CancellationError() }
            catch { lastCandidateError = error.localizedDescription }
        }
        await progress(L("LaunchServices DBの場所を探しています…"))
        do {
            return try await finder.find(accept: { path in
                do { return try await self.readDeviceCatalog(path: path, group: group) }
                catch is CancellationError { throw CancellationError() }
                catch { await self.noteCandidateError(error.localizedDescription); return nil }
            }, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let lastCandidateError { throw RunnerError(localized: "\(String(describing: error.localizedDescription))\n最後の候補: \(String(describing: lastCandidateError))") }
            throw error
        }
    }

    private func noteCandidateError(_ message: String) { lastCandidateError = message }

    private func readDeviceCatalog(path: String, group: String) async throws -> ApplicationCatalogSnapshot {
        let catalog = try await files.readLaunchServicesCatalog(path: path, group: group)
        try Task.checkCancellation()
        guard catalog.applications.contains(where: { $0.kind == .application }) else {
            throw RunnerError(localized: "このDBには現在利用できるアプリの記録がありません。別のDBを自動検索します。")
        }
        return ApplicationCatalogSnapshot(catalog: catalog, sourcePath: path, loadedAt: Date())
    }
}
