import Foundation

enum AppGroupPaths {
    static let root = LaunchServicesPaths.groupRoot
    static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"

    static func container(_ raw: String) -> String? {
        guard let path = try? WallpaperPaths.normalized(raw) else { return nil }
        return LaunchServicesPaths.container(path, root: root)
    }

    static func child(_ name: String) -> String? {
        guard name.count == 36, let id = UUID(uuidString: name) else { return nil }
        return root + "/" + id.uuidString
    }

    static func identifier(from data: Data, container: String) throws -> String {
        guard data.count <= 1_048_576, let path = Self.container(container),
              let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = value["MCMMetadataIdentifier"] as? String,
              identifier.rangeOfCharacter(from: .controlCharacters) == nil,
              identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,511}$"#, options: .regularExpression) != nil else {
            throw RunnerError(localized: "App Groupの管理情報からグループIDを確認できません。")
        }
        if let recorded = value["MCMMetadataUUID"] {
            guard let string = recorded as? String, let id = UUID(uuidString: string),
                  id.uuidString == URL(fileURLWithPath: path).lastPathComponent else {
                throw RunnerError(localized: "App Groupの管理情報とフォルダのUUIDが一致しません。")
            }
        }
        // A group identifier is not evidence of a particular app's membership.
        return identifier
    }
}

struct AppGroupContainer: Identifiable, Sendable {
    let path: String
    let groupID: String?
    let canOpen: Bool
    let issues: [String]
    var identificationSource: String? = nil
    var id: String { path }
    var uuid: String { URL(fileURLWithPath: path).lastPathComponent }
    var title: String { groupID ?? L("グループID不明") }
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query) || path.localizedStandardContains(query)
    }
}

struct AppGroupScanSnapshot: Sendable {
    let containers: [AppGroupContainer]
    let scannedCount: Int
    let candidateCount: Int
    let missingCount: Int
    let skippedCount: Int
    let rootIssue: String?
    let catalogIssue: String?
    var phase = L("共有フォルダを確認中…")
}

protocol AppGroupAccess: Actor {
    func appGroupCandidateNames() async throws -> [String]
    func inspectAppGroup(path: String) async throws -> AppGroupContainer?
}

actor AppGroupScanner {
    static let maximumContainers = 4096
    private let files: any AppGroupAccess
    private struct CacheKey: Equatable, Sendable {
        let knownPaths: [String]
        let catalog: ParsedApplicationCatalog?
        let catalogLoadedAt: Date?
    }
    private var cache = SessionReadCache<CacheKey, AppGroupScanSnapshot>()
    init(files: any AppGroupAccess) {
        self.files = files
    }

    /// Reuses the session cache until it is explicitly invalidated. The first
    /// scan, or a user-requested refresh, performs the filesystem reads;
    /// returning to the screen does not.
    func scan(knownPaths: [String], catalog: ParsedApplicationCatalog? = nil, catalogIssue: String? = nil,
              catalogLoadedAt: Date? = nil, forceRefresh: Bool = false,
              progress: @Sendable (AppGroupScanSnapshot) async -> Void = { _ in }) async throws -> AppGroupScanSnapshot {
        try Task.checkCancellation()
        let key = CacheKey(knownPaths: Set(knownPaths.compactMap(AppGroupPaths.container)).sorted(), catalog: catalog,
                           catalogLoadedAt: catalogLoadedAt)
        if !forceRefresh, catalogIssue == nil, let snapshot = cache.value(for: key) { return snapshot }
        let token = cache.invalidate()
        let snapshot = try await read(knownPaths: key.knownPaths, catalog: catalog, catalogIssue: catalogIssue, progress: progress)
        try Task.checkCancellation()
        // A completed scan is reusable even when the parent directory could not
        // be listed or the result is empty. Re-reading is then an explicit user
        // action ("更新"), not something that happens on every screen visit.
        // A DB read failure is not cached so it can be retried.
        if catalogIssue == nil {
            cache.store(snapshot, for: key, token: token)
        }
        return snapshot
    }

    func invalidateCache() { cache.invalidate() }

    private func read(knownPaths: [String], catalog: ParsedApplicationCatalog?, catalogIssue: String?,
              progress: @Sendable (AppGroupScanSnapshot) async -> Void = { _ in }) async throws -> AppGroupScanSnapshot {
        try Task.checkCancellation()
        var candidates = Set(knownPaths.compactMap(AppGroupPaths.container))
        candidates.formUnion(catalog?.sharedGroupPaths.compactMap(AppGroupPaths.container) ?? [])
        let identifiers = catalog?.sharedGroupIdentifiers ?? [:]
        candidates.formUnion(identifiers.keys.compactMap(AppGroupPaths.container))
        var rootIssue: String?
        do {
            for name in try await files.appGroupCandidateNames() {
                if let path = AppGroupPaths.child(name) { candidates.insert(path) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { rootIssue = L("共有フォルダの一覧を取得できません。DBに記録された候補だけを確認します。\n\(String(describing: error.localizedDescription))") }
        try Task.checkCancellation()
        guard candidates.count <= Self.maximumContainers else { throw RunnerError(localized: "App Groupsの探索上限（4,096コンテナ）を超えています。") }
        var containers: [AppGroupContainer] = [], scanned = 0, missing = 0, skipped = 0
        var phase = L("共有フォルダを確認中…")
        func snapshot() -> AppGroupScanSnapshot {
            AppGroupScanSnapshot(containers: containers, scannedCount: scanned, candidateCount: candidates.count,
                                 missingCount: missing, skippedCount: skipped, rootIssue: rootIssue,
                                 catalogIssue: catalogIssue, phase: phase)
        }
        func identify(_ group: AppGroupContainer) -> AppGroupContainer {
            let ids = identifiers[group.path] ?? []
            var issues = group.issues
            let id: String?, source: String?
            if let metadata = group.groupID {
                id = metadata; source = L("コンテナ管理情報")
                if !ids.isEmpty && ids != [metadata] { issues.append(L("管理情報とDBのグループIDが競合しています。管理情報を優先します。")) }
            } else if ids.count == 1 {
                id = ids.first; source = L("LaunchServices DB")
            } else {
                id = nil; source = nil
                if ids.count > 1 { issues.append(L("DBの同じ共有フォルダに複数のグループIDが記録されています。推測による特定は行いません。")) }
            }
            return AppGroupContainer(path: group.path, groupID: id, canOpen: group.canOpen, issues: issues,
                                     identificationSource: source)
        }
        for path in candidates.sorted() {
            try Task.checkCancellation()
            do {
                if let group = try await files.inspectAppGroup(path: path) { containers.append(identify(group)) }
                else { skipped += 1 } // Not a real directory; never follow links.
            } catch is CancellationError { throw CancellationError() }
            catch where (error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(ENOENT) { missing += 1 }
            catch {
                containers.append(identify(AppGroupContainer(path: path, groupID: nil, canOpen: false,
                    issues: [L("存在・読み取り可否を確認できません。\n\(String(describing: error.localizedDescription))")])))
            }
            scanned += 1
            if scanned == 1 || scanned.isMultiple(of: 8) {
                try Task.checkCancellation()
                await progress(snapshot())
                try Task.checkCancellation()
            }
        }
        phase = L("探索完了（確認できた範囲）")
        containers.sort {
            if ($0.groupID != nil) != ($1.groupID != nil) { return $0.groupID != nil }
            return $0.title == $1.title ? $0.path < $1.path : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        try Task.checkCancellation()
        return snapshot()
    }
}
