import Foundation
import Darwin
#if SWIFT_PACKAGE
import NativeBridge
#endif

// All filesystem operations and worse_query calls share one actor. The upstream
// PoC temporarily changes App Group Caches, so concurrent calls are unsafe.
actor FileAccessManager: WallpaperLibraryAccess, AppGroupAccess, ApplicationCatalogAccess {
    private let files = FileManager.default
    private var grants: [String: AccessGrant] = [:]
    private var scopes: [URL] = []
    private var accessDepth = 0
    private let testAccess: SandboxAccessBackend?
    let backupRoot: URL
    let temporaryRoot: URL
    let cachesRoot: URL
    private var pendingWrites: [UUID: FileWriteOperation] = [:]
    private var stagedWriteDirectories: [UUID: URL] = [:]
    private var pendingWallpaperChanges: [UUID: PendingWallpaperChange] = [:]
    private var pendingWallpaperRefreshes: [UUID: WallpaperBackupMetadata] = [:]
    private var pendingKeypadChanges: [UUID: KeypadWritePlan] = [:]
    private let previewLimit = 1_048_576
    private var stagedPreviewDirectories = Set<URL>()
    private var preferredAlternateFlags: Bool?

    init(backupRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TaiKueriRunner/Backups", isDirectory: true), accessBackend: SandboxAccessBackend? = nil,
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         cachesRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) {
        self.backupRoot = backupRoot
        self.temporaryRoot = temporaryRoot
        self.cachesRoot = cachesRoot
        self.testAccess = accessBackend
    }

    private var activeStagingDirectories: Set<URL> {
        stagedPreviewDirectories.union(stagedWriteDirectories.values)
    }

    private func acquire(path rawPath: String, group: String) throws -> [AccessGrant] {
        let path = try FileRules.canonical(rawPath)
        if grants[path] != nil { return currentGrants() }
        if let testAccess {
            grants[path] = AccessGrant(path: path, handle: try testAccess.acquire(path), created: Date())
            return currentGrants()
        }
        guard RuntimeSupport.isReportedSupported(ProcessInfo.processInfo.operatingSystemVersion) else {
            throw RunnerError(localized: "このOSはアプリの実行許可範囲（\(String(describing: RuntimeSupport.allowedVersionRange))）外です。実行を中止しました。")
        }
        guard !group.isEmpty, let root = files.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw RunnerError(localized: "App Groupにアクセスできません。AltStore・SideStore・SideloadlyでApple IDを使って再インストールしてください。App Groupsの宣言を削除しない設定にしてください。")
        }
        // Upstream deletes Library/Caches. Never allow it to delete existing data.
        let caches = root.appendingPathComponent("Library/Caches")
        try files.createDirectory(at: caches.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? files.attributesOfItem(atPath: caches.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw RunnerError(localized: "App GroupのCachesが通常のディレクトリではありません。安全のため中止しました。")
            }
            guard try files.contentsOfDirectory(atPath: caches.path).isEmpty else {
                throw RunnerError(localized: "App GroupのCachesが空ではありません。専用のApp Groupを使用してください（既存データは削除しません）。")
            }
        } else {
            try files.createDirectory(at: caches, withIntermediateDirectories: false)
        }
        let result = try SandboxGrantPolicy.acquire(
            preferAlternate: preferredAlternateFlags ?? SandboxGrantPolicy.prefersAlternateFlags(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            query: { alternate in
                let handle = worse_query(path, group, alternate, false)
                // Recover only our temporary symlink if upstream exited early.
                if (try? self.files.attributesOfItem(atPath: caches.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                    try? self.files.removeItem(at: caches)
                    try? self.files.createDirectory(at: caches, withIntermediateDirectories: false)
                }
                return handle
            }, sandboxAllowsOpen: {
                let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                if fd >= 0 { close(fd); return true }
                // EACCES is a Unix owner/mode refusal, not a failed sandbox token.
                return errno != EPERM
            }, release: { worse_query_release($0) })
        if preferredAlternateFlags == nil { preferredAlternateFlags = result.alternateFlags }
        grants[path] = AccessGrant(path: path, handle: result.handle, created: Date())
        return currentGrants()
    }

    private func release(path: String) -> [AccessGrant] {
        if let grant = grants.removeValue(forKey: path) { releaseHandle(grant.handle) }
        return currentGrants()
    }

    func releaseAll() {
        for grant in grants.values { releaseHandle(grant.handle) }
        grants.removeAll()
        // Stored picker URLs are inactive; discard the ability to reopen them.
        scopes.removeAll()
        pendingWrites.removeAll()
        pendingWallpaperChanges.removeAll()
        pendingWallpaperRefreshes.removeAll()
        pendingKeypadChanges.removeAll()
        for directory in stagedWriteDirectories.values { try? files.removeItem(at: directory) }
        stagedWriteDirectories.removeAll()
    }

    private func releaseHandle(_ handle: Int64) {
        if let testAccess { testAccess.release(handle) } else { worse_query_release(handle) }
    }

    // No await inside a filesystem session: reads nested within a write retain
    // their grants until the entire backup/write transaction finishes.
    private func withAccessSession<T>(_ operation: () throws -> T) rethrows -> T {
        let outermost = accessDepth == 0
        let activeScopes = outermost ? scopes.filter { $0.startAccessingSecurityScopedResource() } : []
        accessDepth += 1
        defer {
            accessDepth -= 1
            if outermost {
                for grant in grants.values { releaseHandle(grant.handle) }
                grants.removeAll()
                for scope in activeScopes { scope.stopAccessingSecurityScopedResource() }
            }
        }
        return try operation()
    }

    func currentGrants() -> [AccessGrant] { grants.values.sorted { $0.path < $1.path } }

    // Reads are always allowed by app policy. Only an OS permission denial triggers
    // a bounded grant attempt; missing files, invalid data and cancellation do not.
    private func withReadAccess<T>(path: String, directory: Bool = false, operation: () throws -> T) throws -> T {
        try withAccessSession { try readWithPermissionRetry(path: path, directory: directory, operation: operation) }
    }

    private func readWithPermissionRetry<T>(path: String, directory: Bool, preserveDenial: Bool = false, operation: () throws -> T) throws -> T {
        let path = try FileRules.canonical(path)
        do { return try operation() }
        catch {
            guard Self.isPermissionDenial(error), testAccess != nil || (RuntimeSupport.appGroup != nil &&
                  RuntimeSupport.isReportedSupported(ProcessInfo.processInfo.operatingSystemVersion)) else { throw error }
            var lastError = error
            let targets = directory ? [path] : [URL(fileURLWithPath: path).deletingLastPathComponent().path, path]
            for target in targets {
                try Task.checkCancellation()
                do {
                    _ = try acquire(path: target, group: RuntimeSupport.groupID)
                } catch {
                    lastError = error
                    continue
                }
                do { return try operation() }
                catch {
                    guard Self.isPermissionDenial(error) else { throw error }
                    lastError = error
                }
            }
            if preserveDenial {
                // Export may omit unreadable sources. Keep the original denial
                // class even when an attempted grant itself fails for another reason.
                let original = error as NSError
                throw NSError(domain: original.domain, code: original.code, userInfo: [
                    NSLocalizedDescriptionKey: lastError.localizedDescription,
                    NSUnderlyingErrorKey: original
                ])
            }
            throw lastError
        }
    }

    private static func isPermissionDenial(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EACCES) || error.code == Int(EPERM) }
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenial(underlying) }
        return false
    }

    func readLaunchServicesCatalog(path: String, group: String) throws -> ParsedApplicationCatalog {
        guard let targets = LaunchServicesPaths.accessTargets(forStore: path) else {
            throw RunnerError(localized: "lsdのInternalDaemon/UUID/Library/Caches内のCSStoreを指定してください。")
        }
        do {
            return try StableFileReader.read(path: path, maximumBytes: CSStoreParser.maximumBytes, decode: CSStoreParser.parse)
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
            // Match WQFiles: the file's immediate parent first, then the file.
            // Both targets are inside the same validated daemon container.
            var temporaryGrants: [String] = []
            defer { for target in temporaryGrants { _ = release(path: target) } }
            var lastError: Error = error
            for target in targets {
                try Task.checkCancellation()
                let ownsGrant = grants[target] == nil
                do { _ = try acquire(path: target, group: group) }
                catch { lastError = error; continue }
                if ownsGrant { temporaryGrants.append(target) }
                do {
                    return try StableFileReader.read(path: path, maximumBytes: CSStoreParser.maximumBytes, decode: CSStoreParser.parse)
                } catch let denial as POSIXError where denial.code == .EACCES || denial.code == .EPERM {
                    lastError = denial
                }
            }
            throw lastError
        }
    }

    func appGroupCandidateNames() throws -> [String] {
        try Task.checkCancellation()
        return try withAccessSession {
            try validateAppGroupAncestors()
            let list = {
                let names = try self.files.contentsOfDirectory(atPath: AppGroupPaths.root)
                guard names.count <= 16_384 else { throw RunnerError(localized: "App Groupsルートの項目数が上限を超えています。") }
                return names
            }
            // iOS 26 cannot normally grant the AppGroup parent. Try ordinary
            // enumeration only; the scanner can still inspect DB UUID candidates.
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26, testAccess == nil { return try list() }
            return try withReadAccess(path: AppGroupPaths.root, directory: true, operation: list)
        }
    }

    func inspectAppGroup(path rawPath: String) throws -> AppGroupContainer? {
        try Task.checkCancellation()
        guard let path = AppGroupPaths.container(rawPath) else { throw RunnerError(localized: "AppGroup/UUIDの共有コンテナ以外は探索できません。") }
        return try withAccessSession {
            try validateAppGroupAncestors()
            let original = try withReadAccess(path: path, directory: true) { try FileBackupStore.Snapshot(path: path) }
            guard original.isDirectory else { return nil }
            var issues: [String] = [], canOpen = false
            do {
                try withReadAccess(path: path, directory: true) {
                    // Prove readability without collecting a shared folder's
                    // potentially huge file list or traversing its children.
                    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    guard let directory = fdopendir(fd) else {
                        let code = errno
                        close(fd)
                        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    }
                    defer { closedir(directory) }
                    errno = 0
                    _ = readdir(directory)
                    guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
                canOpen = true
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(L("フォルダを読み取れません。\n\(String(describing: error.localizedDescription))")) }
            var identifier: String?
            do {
                let metadata = path + "/" + AppGroupPaths.metadataName
                identifier = try withReadAccess(path: metadata) {
                    try StableFileReader.read(path: metadata, maximumBytes: 1_048_576) {
                        try AppGroupPaths.identifier(from: $0, container: path)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(L("コンテナ管理情報からはグループIDを確認できません。\n\(String(describing: error.localizedDescription))")) }
            let current = try withReadAccess(path: path, directory: true) { try FileBackupStore.Snapshot(path: path) }
            guard current.isDirectory, current.device == original.device, current.inode == original.inode else {
                throw RunnerError(localized: "探索中にApp Groupのフォルダが変更・置換されました。")
            }
            return AppGroupContainer(path: path, groupID: identifier, canOpen: canOpen, issues: issues)
        }
    }

    private func validateAppGroupAncestors() throws {
        for path in try WallpaperPaths.directoryAncestors(AppGroupPaths.root, container: "/var/mobile") {
            let snapshot = try withReadAccess(path: path, directory: true) { try FileBackupStore.Snapshot(path: path) }
            guard snapshot.isDirectory else { throw RunnerError(localized: "App Groupsの親パスにリンクまたは通常フォルダ以外の項目があります。") }
        }
    }

    func openScopedDirectory(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try files.contentsOfDirectory(atPath: url.path)
        if accessed && !scopes.contains(url) { scopes.append(url) }
        return url.path
    }

    func list(path: String, showHidden: Bool) throws -> [FileEntry] {
        try withReadAccess(path: path, directory: true) { try listContents(path: path, showHidden: showHidden) }
    }

    func resolveLink(_ entry: FileEntry) throws -> FileEntry {
        try withReadAccess(path: entry.path) {
            let resolved = entry.url.resolvingSymlinksInPath()
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return FileEntry(path: resolved.path, name: resolved.lastPathComponent, isDirectory: values.isDirectory == true,
                             isSymbolicLink: false, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
    }

    private func listContents(path: String, showHidden: Bool) throws -> [FileEntry] {
        try Task.checkCancellation()
        let root = URL(fileURLWithPath: try FileRules.canonical(path))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            if let values = try? url.resourceValues(forKeys: keys) {
                let link = values.isSymbolicLink == true
                entries.append(FileEntry(path: url.path, name: url.lastPathComponent,
                                         isDirectory: !link && values.isDirectory == true, isSymbolicLink: link,
                                         size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
            } else {
                // Preserve listability when metadata cannot be prefetched for an item.
                let attrs = (try? files.attributesOfItem(atPath: url.path)) ?? [:]
                let type = attrs[.type] as? FileAttributeType
                entries.append(FileEntry(path: url.path, name: url.lastPathComponent, isDirectory: type == .typeDirectory,
                                         isSymbolicLink: type == .typeSymbolicLink, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                                         modified: attrs[.modificationDate] as? Date))
            }
        }
        try Task.checkCancellation()
        return entries
    }

    func readText(path: String) throws -> String {
        try withReadAccess(path: path) {
            try StableFileReader.read(path: path, maximumBytes: previewLimit) { data in
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                    throw RunnerError(localized: "UTF-8テキストではありません。16進数表示または共有メニューを使用してください。")
                }
                return text
            }
        }
    }

    func readPropertyListPreview(path: String) throws -> PropertyListDocumentPreview {
        try withReadAccess(path: path) {
            try StableFileReader.read(path: path, maximumBytes: DocumentPreview.maximumPlistBytes, decode: DocumentPreview.propertyList)
        }
    }

    func readMobileGestalt(path: String) throws -> MobileGestaltDocument {
        try withReadAccess(path: path) {
            try StableFileReader.read(path: path, maximumBytes: DocumentPreview.maximumPlistBytes) {
                try MobileGestaltDocument(path: path, data: $0)
            }
        }
    }

    func readMobileGestalt(url: URL) throws -> MobileGestaltDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let document = try readMobileGestalt(path: url.path)
        if accessed && !scopes.contains(url) { scopes.append(url) }
        return document
    }

    func backups() throws -> FileBackupListing { try FileBackupStore(root: backupRoot).list() }

    func appCacheUsage() -> AppCacheUsage {
        AppCacheStore(temporaryRoot: temporaryRoot, cachesRoot: cachesRoot)
            .usage(activeDirectories: activeStagingDirectories)
    }

    func clearAppCache() -> AppCacheCleanupResult {
        AppCacheStore(temporaryRoot: temporaryRoot, cachesRoot: cachesRoot)
            .cleanup(activeDirectories: activeStagingDirectories)
    }

    func purgeOrphanedStagingFiles() -> AppCacheCleanupResult {
        AppCacheStore(temporaryRoot: temporaryRoot, cachesRoot: cachesRoot)
            .purgeStaging(activeDirectories: activeStagingDirectories)
    }

    func deleteBackups(ids: [String]) throws -> FileBackupDeletion {
        try Task.checkCancellation()
        let requested = Set(ids)
        guard !requested.isEmpty else { throw RunnerError(localized: "削除するバックアップを選択してください。") }
        guard requested.count <= 5_000 else { throw RunnerError(localized: "一度に削除できるバックアップは5,000件までです。") }
        for operation in pendingWrites.values {
            if case .restoreBackup(let id) = operation, requested.contains(id) {
                throw RunnerError(localized: "復元確認中のバックアップは削除できません。先に確認をキャンセルしてください。")
            }
        }
        let store = FileBackupStore(root: backupRoot)
        var removed: [String] = [], failed: [String] = [], freed: Int64 = 0
        for id in requested.sorted() {
            try Task.checkCancellation()
            do {
                freed += try store.delete(id: id)
                removed.append(id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(id)
            }
        }
        return FileBackupDeletion(removed: removed, failed: failed, freedBytes: freed)
    }

    private func writePaths(_ operation: FileWriteOperation) throws -> (source: URL?, destination: URL?) {
        guard case .restoreBackup(let id) = operation else { return try operation.paths() }
        let plan = try FileBackupStore(root: backupRoot).record(id: id).restoration()
        let target = URL(fileURLWithPath: try FileRules.canonical(plan.path))
        do {
            _ = try withReadAccess(path: target.path) { try FileBackupStore.Snapshot(path: target.path) }
            return (target, target)
        } catch let error as POSIXError where error.code == .ENOENT {
            if case .removeCreated = plan { throw RunnerError(localized: "作成した項目は既に存在しません。") }
            return (nil, target)
        }
    }

    func readHexPreview(path: String) throws -> HexDocumentPreview {
        try withReadAccess(path: path) {
            try StableFileReader.withFile(path: path, maximumBytes: Int.max) { handle, size in
                var data = Data()
                let limit = min(size, DocumentPreview.maximumHexBytes)
                while data.count < limit {
                    try Task.checkCancellation()
                    let bytes = try handle.read(upToCount: limit - data.count) ?? Data()
                    if bytes.isEmpty { break }
                    data.append(bytes)
                }
                return HexDocumentPreview(text: DocumentPreview.hexDump(data), totalBytes: size, shownBytes: data.count)
            }
        }
    }

    func stageDocumentPreview(path: String, maximumBytes: Int = DocumentPreview.maximumMediaBytes) throws -> StagedDocumentPreview {
        guard maximumBytes > 0, maximumBytes <= FileBackupStore.maximumBytes else { throw RunnerError(localized: "一時コピーのサイズ上限が不正です。") }
        let directory = temporaryRoot.appendingPathComponent("DocumentPreview-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        do {
            try withReadAccess(path: path) {
                try StableFileReader.withFile(path: path, maximumBytes: maximumBytes) { input, size in
                    guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RunnerError(localized: "プレビュー用の一時ファイルを作成できません。") }
                    let output = try FileHandle(forWritingTo: url)
                    defer { try? output.close() }
                    var copied = 0
                    while copied <= maximumBytes {
                        try Task.checkCancellation()
                        let bytes = try input.read(upToCount: min(1_048_576, maximumBytes - copied + 1)) ?? Data()
                        if bytes.isEmpty { break }
                        copied += bytes.count
                        guard copied <= maximumBytes else { throw RunnerError(localized: "一時コピー中にファイルサイズが上限を超えました。") }
                        try output.write(contentsOf: bytes)
                    }
                    guard copied == size else { throw RunnerError(localized: "プレビュー中に元ファイルが変更されました。") }
                }
            }
            stagedPreviewDirectories.insert(directory)
            return StagedDocumentPreview(url: url, directory: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func closeDocumentPreview(_ preview: StagedDocumentPreview) {
        // Never remove a directory supplied by another caller or a source path.
        if stagedPreviewDirectories.remove(preview.directory) != nil { try? files.removeItem(at: preview.directory) }
    }

    func stageApplicationDataExport(application: CatalogApplication, path: String) throws -> ApplicationDataExport.StagedExport {
        guard let container = LaunchServicesPaths.dataContainer(path),
              application.containerPaths.contains(where: { LaunchServicesPaths.dataContainer($0) == container }) else {
            throw RunnerError(localized: "選択したアプリのデータコンテナだけをエクスポートできます。")
        }
        return try stageDataExport(container: container,
                                   filename: ApplicationDataExport.archiveFilename(bundleID: application.bundleID),
                                   stagingPrefix: "ApplicationDataExport")
    }

    func stageAppGroupDataExport(group: AppGroupContainer, path: String) throws -> ApplicationDataExport.StagedExport {
        // Only the selected App Group's UUID container can be exported. The
        // group must have passed the read check in the scanner before this runs.
        guard group.canOpen,
              let container = AppGroupPaths.container(path),
              AppGroupPaths.container(group.path) == container else {
            throw RunnerError(localized: "選択したApp Groupの共有フォルダだけをエクスポートできます。")
        }
        let identifier = group.groupID ?? group.uuid
        return try stageDataExport(container: container,
                                   filename: ApplicationDataExport.archiveFilename(identifier: identifier),
                                   stagingPrefix: "AppGroupDataExport")
    }

    // Shared staging for app containers and App Group containers. Callers own
    // authorization; the copy / report / ZIP / cleanup sequence is identical.
    private func stageDataExport(container: String, filename: String, stagingPrefix: String) throws -> ApplicationDataExport.StagedExport {
        try Task.checkCancellation()
        let directory = temporaryRoot.appendingPathComponent("\(stagingPrefix)-\(UUID().uuidString)", isDirectory: true)
        let payload = directory.appendingPathComponent("Data", isDirectory: true)
        let archive = directory.appendingPathComponent(filename)
        var phase = L("作業フォルダの作成")
        var created = false
        do {
            guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            created = true
            phase = L("元データのコピー")
            let report = try copyApplicationData(path: container, to: payload)
            phase = L("省略レポートの作成")
            let reportData = try report.encoded()
            // No source grant remains while the in-process writer creates ZIP.
            phase = L("ZIP生成（元データの読み取り後）")
            try ApplicationDataExport.archive(directory: payload, to: archive, report: reportData)
            phase = L("作業用コピーの整理")
            try files.removeItem(at: payload)
            try Task.checkCancellation()
            stagedPreviewDirectories.insert(directory)
            return ApplicationDataExport.StagedExport(document: StagedDocumentPreview(url: archive, directory: directory), report: report)
        } catch {
            if created { try? files.removeItem(at: directory) }
            if error is CancellationError { throw CancellationError() }
            throw ApplicationDataExport.Failure(phase: phase, underlying: error)
        }
    }

    // Shared source-copy session, separate from catalog selection and ZIP creation
    // so all acquired handles stay alive through traversal and verification.
    @discardableResult
    func copyApplicationData(path: String, to destination: URL) throws -> ApplicationDataExport.Report {
        let container = try FileRules.canonical(path)
        return try withAccessSession {
            try ApplicationDataExport.copy(source: URL(fileURLWithPath: container), to: destination) { path, directory, operation in
                let target = try FileRules.canonical(path)
                guard target == container || target.hasPrefix(container + "/") else {
                    throw RunnerError(localized: "選択したコンテナの外にはアクセスできません。")
                }
                // Directory listing alone does not prove descendants are
                // readable. Retry only the specific source operation denied.
                try readWithPermissionRetry(path: target, directory: directory, preserveDenial: true, operation: operation)
            }
        }
    }

    func stageSQLitePreview(path: String) throws -> StagedDocumentPreview {
        let directory = temporaryRoot.appendingPathComponent("SQLitePreview-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("snapshot.sqlite")
        do {
            try withReadAccess(path: path) {
                // A permission retry must not reuse a partial DB/WAL pair.
                for copy in [url, URL(fileURLWithPath: url.path + "-wal")] where files.fileExists(atPath: copy.path) {
                    try files.removeItem(at: copy)
                }
                try SQLiteSnapshot.copy(path: path, to: url)
            }
            stagedPreviewDirectories.insert(directory)
            return StagedDocumentPreview(url: url, directory: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    // LINE app-container attachments are ordinary files next to the app's
    // PrivateStore. Directory listing, reads and copies use the same per-path
    // permission retry as the shared container.
    func listLINEMediaFiles(path: String) throws -> [String] {
        try withReadAccess(path: path, directory: true) {
            let names = try files.contentsOfDirectory(atPath: path)
            guard names.count <= 10_000 else {
                throw RunnerError(localized: "LINEの添付フォルダの項目数が上限を超えています。")
            }
            return names
        }
    }

    func copyLINEMediaFile(path: String, to destination: URL, maximumBytes: Int) throws {
        guard maximumBytes > 0, maximumBytes <= 2 * 1024 * 1024 * 1024 else {
            throw RunnerError(localized: "一時コピーのサイズ上限が不正です。")
        }
        try withReadAccess(path: path) {
            try StableFileReader.withFile(path: path, maximumBytes: maximumBytes) { input, size in
                guard files.createFile(atPath: destination.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600]) else {
                    throw RunnerError(localized: "LINEの添付ファイル用の一時コピーを作成できません。")
                }
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var copied = 0
                while copied < size {
                    try Task.checkCancellation()
                    let bytes = try input.read(upToCount: min(1_048_576, size - copied)) ?? Data()
                    guard !bytes.isEmpty else {
                        throw RunnerError(localized: "LINEの添付ファイルのコピー中にファイルが変わりました。")
                    }
                    try output.write(contentsOf: bytes)
                    copied += bytes.count
                }
            }
        }
    }

    // Live App Group containers store thumbnails and sticker packages as
    // ordinary files. StableFileReader rejects links and detects concurrent
    // changes, while withReadAccess preserves the per-path permission retry.
    func readLINEMediaFile(path: String, maximumBytes: Int) throws -> Data {
        try withReadAccess(path: path) {
            try StableFileReader.read(path: path, maximumBytes: maximumBytes) { $0 }
        }
    }

    // Lightweight existence check for gallery filtering. Reading the whole
    // thumbnail just to decide whether a row is displayable would be wasteful,
    // and checking each image in its own access session would repeatedly
    // acquire the same container grant. The caller gets the definitely present
    // paths and the paths whose state is unknown (permission denied), so it can
    // keep unknown items visible instead of treating them as missing.
    func lineMediaFilesExist(paths: [String]) throws -> (present: Set<String>, unknown: Set<String>) {
        var present = Set<String>(), unknown = Set<String>()
        try withAccessSession {
            for path in paths {
                try Task.checkCancellation()
                do {
                    let exists = try readWithPermissionRetry(path: path, directory: false) {
                        do { return try FileBackupStore.Snapshot(path: path).isRegular }
                        catch let error as POSIXError where error.code == .ENOENT { return false }
                    }
                    if exists { present.insert(path) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    unknown.insert(path)
                }
            }
        }
        return (present, unknown)
    }

    // LINE viewer: inspect a live App Group container (as found by the LINE
    // viewer's automatic scan) without copying anything. Only paths that
    // resolve to a container under the App Group root are accepted. Every
    // directory listing and file stat goes through the per-path permission
    // retry, exactly like the export walk: a container-root grant alone does
    // not make deeper paths readable on device.
    func readLINEArchiveSummary(containerPath: String) throws -> LINEArchiveSummary? {
        guard let container = AppGroupPaths.container(containerPath) else {
            throw RunnerError(localized: "App Groupの共有フォルダだけを対象にできます。")
        }
        return try withAccessSession {
            try LINEDataStaging.inspect(container: container, access: lineStagingAccess())
        }
    }

    // Copies the LINE chat databases straight out of a live App Group
    // container. The container itself is only ever read; the LINE app should
    // be closed while the snapshot copies are being taken.
    func stageLINEData(containerPath: String, summary: LINEArchiveSummary, includeOpenChat: Bool) throws -> StagedDocumentPreview {
        guard let container = AppGroupPaths.container(containerPath) else {
            throw RunnerError(localized: "App Groupの共有フォルダだけを対象にできます。")
        }
        let messages = container + "/" + LINEDataStaging.privateStoreRelative + "/P_\(summary.accountMID)/Messages"
        let directory = temporaryRoot.appendingPathComponent("LINEDataPreview-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try withAccessSession {
                try LINEDataStaging.extract(messages: messages, summary: summary,
                                           includeOpenChat: includeOpenChat, to: directory, access: lineStagingAccess())
            }
            stagedPreviewDirectories.insert(directory)
            return StagedDocumentPreview(url: directory.appendingPathComponent("Line.sqlite"), directory: directory)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    // Wraps each LINE staging operation in the shared per-path retry so an OS
    // denial triggers the bounded grant acquisition for the exact path, the
    // same contract the application data export relies on.
    private func lineStagingAccess() -> LINEDataStaging.LINEStagingAccess {
        LINEDataStaging.LINEStagingAccess(
            listDirectory: { path in
                try self.readWithPermissionRetry(path: path, directory: true) {
                    try self.files.contentsOfDirectory(atPath: path)
                }
            },
            regularFileSize: { path in
                try self.readWithPermissionRetry(path: path, directory: false) {
                    var info = stat()
                    guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    guard info.st_mode & S_IFMT == S_IFREG else { throw RunnerError(localized: "LINEのDBへのリンク・特殊ファイルは読み取れません。") }
                    return Int(info.st_size)
                }
            },
            copyFile: { source, destination, size in
                try self.readWithPermissionRetry(path: source, directory: false) {
                    try LINEDataStaging.copyFile(source: source, expectedSize: size, to: URL(fileURLWithPath: destination))
                }
            }
        )
    }

    func prepareWrite(_ operation: FileWriteOperation) throws -> FileWriteRequest {
        if case .replaceKeypad = operation { throw RunnerError(localized: "キーパッドの変更は専用画面から確認してください。") }
        let (source, destination) = try writePaths(operation)
        let store = FileBackupStore(root: backupRoot)
        if let source { try store.protect(source) }
        if let destination { try store.protect(destination) }
        if case .rename = operation, source == destination { throw RunnerError(localized: "別の名前を指定してください。") }
        let details: String?
        if case .restoreBackup(let id) = operation { details = try store.record(id: id).restorationNote + "\n" + L("バックアップID: \(String(describing: id))") }
        else { details = nil }
        let request = FileWriteRequest(id: UUID(), title: operation.title, sourcePath: source?.path, destinationPath: destination?.path, details: details)
        pendingWrites[request.id] = operation
        return request
    }

    func cancelWrite(_ request: FileWriteRequest) {
        pendingWrites.removeValue(forKey: request.id)
        pendingWallpaperChanges.removeValue(forKey: request.id)
        pendingWallpaperRefreshes.removeValue(forKey: request.id)
        pendingKeypadChanges.removeValue(forKey: request.id)
        if let directory = stagedWriteDirectories.removeValue(forKey: request.id) { try? files.removeItem(at: directory) }
    }

    func inspectWallpaperArchive(_ url: URL) throws -> WallpaperArchive {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try WallpaperImporter.inspect(url)
    }

    private func validateKeypadDirectory(_ path: String, expected: FileBackupStore.Snapshot? = nil) throws {
        let root = try KeypadPaths.root(for: path)
        try validateWallpaperAncestors(path, container: root)
        if let expected {
            let current = try withReadAccess(path: path, directory: true) { try FileBackupStore.Snapshot(path: path) }
            guard current.device == expected.device, current.inode == expected.inode, current.isDirectory else {
                throw RunnerError(localized: "キーパッドのキャッシュフォルダが置換されました。再読み込みしてください。")
            }
        }
    }

    func readKeypadDirectory(_ rawPath: String) throws -> [String] {
        try Task.checkCancellation()
        let path = try WallpaperPaths.normalized(rawPath)
        return try withAccessSession {
            try validateKeypadDirectory(path)
            return try withReadAccess(path: path, directory: true) {
                let names = try files.contentsOfDirectory(atPath: path)
                guard names.count <= 10_000 else { throw RunnerError(localized: "キーパッドキャッシュの項目数が上限を超えています。") }
                return names
            }
        }
    }

    func readKeypadFile(path rawPath: String) throws -> KeypadCacheFile {
        try Task.checkCancellation()
        let path = try WallpaperPaths.normalized(rawPath)
        try KeypadPaths.validateFile(path)
        let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent().path
        return try withAccessSession {
            try validateKeypadDirectory(parent)
            let directory = try withReadAccess(path: parent, directory: true) { try FileBackupStore.Snapshot(path: parent) }
            return try withReadAccess(path: path) {
                let snapshot = try FileBackupStore.Snapshot(path: path)
                guard snapshot.isRegular else { throw RunnerError(localized: "キー画像が通常ファイルではありません。") }
                let dimensions = try StableFileReader.withFile(path: path, maximumBytes: KeypadImage.maximumBytes) { handle, _ in
                    try KeypadImage.pngDimensions(handle.read(upToCount: 24) ?? Data())
                }
                guard try FileBackupStore.Snapshot(path: path) == snapshot else { throw RunnerError(localized: "キー画像が読み取り中に変更されました。") }
                return KeypadCacheFile(path: path, name: KeypadAssetName(url.lastPathComponent)!, snapshot: snapshot,
                                       directory: directory, width: dimensions.0, height: dimensions.1)
            }
        }
    }

    func readKeypadPreview(_ entry: KeypadCacheFile) throws -> Data {
        try Task.checkCancellation()
        try KeypadPaths.validateFile(entry.path)
        return try withAccessSession {
            try validateKeypadDirectory(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path, expected: entry.directory)
            return try withReadAccess(path: entry.path) {
                guard try FileBackupStore.Snapshot(path: entry.path) == entry.snapshot else { throw RunnerError(localized: "キー画像が変更されました。") }
                let data = try StableFileReader.read(path: entry.path, maximumBytes: KeypadImage.maximumBytes) { $0 }
                guard try FileBackupStore.Snapshot(path: entry.path) == entry.snapshot else { throw RunnerError(localized: "キー画像が読み取り中に変更されました。再読み込みしてください。") }
                return data
            }
        }
    }

    func prepareKeypadChange(_ plan: KeypadWritePlan) throws -> FileWriteRequest {
        try Task.checkCancellation()
        guard !plan.entries.isEmpty, plan.entries.count <= 1500,
              Set(plan.entries.map { $0.file.path }).count == plan.entries.count,
              plan.entries.reduce(0, { $0 + $1.data.count }) <= Int(FileBackupStore.maximumBytes) else {
            throw RunnerError(localized: "キーパッドの変更対象が不正または上限超過です。")
        }
        for entry in plan.entries {
            try Task.checkCancellation()
            try KeypadPaths.validateFile(entry.file.path)
            guard entry.data.count <= KeypadImage.maximumBytes else { throw RunnerError(localized: "キー画像は16 MiBまでです。") }
            _ = try KeypadImage.pngDimensions(entry.data)
        }
        let request = FileWriteRequest(id: UUID(), title: L("電話のキーパッドを変更"),
            sourcePath: nil, destinationPath: nil,
            details: L("\(String(describing: Set(plan.entries.map { $0.file.name.key }).count))キー / \(String(describing: plan.entries.count))ファイル\n端末で確認できた既存PNGだけを変更します。全対象のバックアップ完了後に書き込みます。途中失敗時の自動巻き戻しはありません。\nパスコードや認証設定は変更しません。反映・実機安全性は未検証です。"))
        pendingKeypadChanges[request.id] = plan
        return request
    }

    func readBatterReplacement(_ url: URL, filter: String?) throws -> Data {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let filter {
            let regex = try NSRegularExpression(pattern: #"\*\.([A-Za-z0-9]+)"#)
            let range = NSRange(filter.startIndex..., in: filter)
            let extensions = regex.matches(in: filter, range: range).compactMap {
                Range($0.range(at: 1), in: filter).map { String(filter[$0]).lowercased() }
            }
            guard extensions.isEmpty || extensions.contains(url.pathExtension.lowercased()) else {
                throw RunnerError(localized: "この設定では\(String(describing: filter))を選択してください。")
            }
        }
        // No file access escalation: read only the explicitly user-selected file.
        return try StableFileReader.read(path: url.path, maximumBytes: WallpaperZIP.maximumFileBytes) { $0 }
    }

    func batterPreview(_ name: String, archive: WallpaperArchive) throws -> Data? {
        let scoped = archive.url.startAccessingSecurityScopedResource()
        defer { if scoped { archive.url.stopAccessingSecurityScopedResource() } }
        return try WallpaperImporter.batterPreview(name, archive: archive)
    }

    func prepareWallpaperImport(_ descriptor: WallpaperDescriptor, archive: WallpaperArchive, container: String,
                                selections: BatterSelections = BatterSelections()) throws -> FileWriteRequest {
        let destination = try WallpaperPaths.descriptors(container: container, provider: descriptor.provider)
        let refresh = try withAccessSession {
            try validateWallpaperDirectory(destination)
            return try wallpaperRefresh(container: container)
        }
        let directory = temporaryRoot.appendingPathComponent("WallpaperImport-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let scoped = archive.url.startAccessingSecurityScopedResource()
            defer { if scoped { archive.url.stopAccessingSecurityScopedResource() } }
            let source = try WallpaperImporter.stage(descriptor, from: archive, in: directory, selections: selections)
            let request = try prepareWrite(.addWallpaper(source: source, directory: destination))
            stagedWriteDirectories[request.id] = directory
            pendingWallpaperChanges[request.id] = PendingWallpaperChange(refresh: refresh,
                metadata: WallpaperBackupMetadata(changeID: request.id, title: descriptor.title, package: archive.url.lastPathComponent, isRefresh: false),
                removal: nil)
            return FileWriteRequest(id: request.id, title: request.title, sourcePath: request.sourcePath, destinationPath: request.destinationPath,
                                    details: L("\(String(describing: descriptor.title))\n同じ名前の壁紙は上書きせず、新しい壁紙として追加します。表示の更新準備もまとめて行います。"))
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func prepareWallpaperRefresh(container: String) throws -> FileWriteRequest {
        return try withAccessSession {
            let refresh = try wallpaperRefresh(container: container)
            let request = try prepareWrite(.savePropertyList(path: refresh.path, data: refresh.data, original: refresh.original))
            pendingWallpaperRefreshes[request.id] = WallpaperBackupMetadata(changeID: request.id, title: L("壁紙の表示を更新"), package: nil, isRefresh: true)
            return FileWriteRequest(id: request.id, title: L("壁紙の表示を更新"), sourcePath: request.sourcePath,
                                    destinationPath: request.destinationPath,
                                    details: L("壁紙が表示されない場合の更新準備をやり直します。完了後に手動でリスプリングしてください。"))
        }
    }

    private func wallpaperRefresh(container: String) throws -> WallpaperRefresh {
        let root = try WallpaperPaths.container(container)
        try validateWallpaperAncestors(root + "/Library/Preferences", container: root)
        let path = root + "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"
        let original = try withReadAccess(path: path) {
            try StableFileReader.read(path: path, maximumBytes: DocumentPreview.maximumPlistBytes) { $0 }
        }
        let data = try WallpaperImporter.refreshSettings(original)
        _ = try PropertyListValue.decode(original)
        _ = try PropertyListValue.decode(data)
        return WallpaperRefresh(path: path, original: original, data: data)
    }

    nonisolated func readWallpaperLibrary(container: String,
        onProgress: @Sendable (WallpaperLibrarySnapshot) async -> Void = { _ in }) async throws -> WallpaperLibrarySnapshot {
        try await WallpaperLibraryWorker(files: self).load(container: container, onProgress: onProgress)
    }

    func readWallpaperDirectory(path: String, container: String) throws -> [FileEntry] {
        try Task.checkCancellation()
        let root = try WallpaperPaths.container(container)
        let directory = try WallpaperPaths.normalized(path)
        return try withAccessSession {
            try validateWallpaperAncestors(directory, container: root)
            return try withReadAccess(path: directory, directory: true) {
                // Only fetch names here. The worker asks for each child's
                // no-follow attributes separately, allowing other I/O between them.
                try files.contentsOfDirectory(atPath: directory).map { name in
                    try Task.checkCancellation()
                    return try WallpaperPaths.listedEntry(
                        FileEntry(path: "", name: name, isDirectory: false, isSymbolicLink: false, size: 0, modified: nil), in: directory)
                }
            }
        }
    }

    func readWallpaperAttributes(path: String, container: String) throws -> FileBackupStore.Snapshot {
        try Task.checkCancellation()
        let root = try WallpaperPaths.container(container), path = try WallpaperPaths.normalized(path)
        return try withAccessSession {
            try validateWallpaperAncestors(path == root ? root : URL(fileURLWithPath: path).deletingLastPathComponent().path, container: root)
            return try withReadAccess(path: path) { try FileBackupStore.Snapshot(path: path) }
        }
    }

    func readWallpaperMetadata(path: String, container: String, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= 4096 else { throw RunnerError(localized: "壁紙名の読み取り上限が不正です。") }
        let root = try WallpaperPaths.container(container), path = try WallpaperPaths.normalized(path)
        return try withAccessSession {
            try validateWallpaperAncestors(URL(fileURLWithPath: path).deletingLastPathComponent().path, container: root)
            return try withReadAccess(path: path) {
                try StableFileReader.read(path: path, maximumBytes: maximumBytes) { $0 }
            }
        }
    }

    func wallpaperBackupIDs() throws -> [String] {
        try Task.checkCancellation()
        var info = stat()
        if lstat(backupRoot.path, &info) != 0, errno == ENOENT { return [] }
        return try files.contentsOfDirectory(atPath: backupRoot.path).filter { UUID(uuidString: $0) != nil }
    }

    func wallpaperBackupRecord(id: String) throws -> FileBackupRecord {
        try Task.checkCancellation()
        return try FileBackupStore(root: backupRoot).record(id: id)
    }

    nonisolated func wallpaperThumbnail(_ item: InstalledWallpaper) async throws -> Data? {
        guard let data = try await readWallpaperThumbnailData(item) else { return nil }
        return try await WallpaperImageWorker.shared.thumbnail(data)
    }

    private func readWallpaperThumbnailData(_ item: InstalledWallpaper) throws -> Data? {
        try Task.checkCancellation()
        guard let preview = item.previewPath else { return nil }
        let path = try WallpaperPaths.normalized(preview), itemPath = try WallpaperPaths.normalized(item.path)
        guard path.hasPrefix(itemPath + "/versions/") else { return nil }
        let location = try WallpaperPaths.installed(item.path)
        return try withAccessSession {
            try validateWallpaperAncestors(URL(fileURLWithPath: path).deletingLastPathComponent().path, container: location.container)
            return try withReadAccess(path: path) {
                try StableFileReader.read(path: path, maximumBytes: WallpaperThumbnail.maximumBytes) { $0 }
            }
        }
    }

    func wallpaperPackageThumbnail(_ descriptor: WallpaperDescriptor, archive: WallpaperArchive) throws -> Data? {
        let scoped = archive.url.startAccessingSecurityScopedResource()
        defer { if scoped { archive.url.stopAccessingSecurityScopedResource() } }
        return try WallpaperImporter.preview(descriptor, archive: archive)
    }

    func prepareWallpaperDeletion(_ item: InstalledWallpaper) throws -> FileWriteRequest {
        try withAccessSession {
            try validateManagedWallpaper(item)
            let location = try WallpaperPaths.installed(item.path)
            let refresh = try wallpaperRefresh(container: location.container)
            let request = try prepareWrite(.delete(path: WallpaperPaths.normalized(item.path)))
            pendingWallpaperChanges[request.id] = PendingWallpaperChange(refresh: refresh,
                metadata: WallpaperBackupMetadata(changeID: request.id, title: item.title, package: nil, isRefresh: false), removal: item)
            return FileWriteRequest(id: request.id, title: L("追加した壁紙を削除"), sourcePath: request.sourcePath, destinationPath: nil,
                                    details: L("\(String(describing: item.title))\nこのアプリで追加した壁紙をバックアップして削除し、表示の更新準備も行います。保存済みのロック画面は変更しません。"))
        }
    }

    private func validateManagedWallpaper(_ item: InstalledWallpaper) throws {
        let location = try WallpaperPaths.installed(item.path)
        guard location.location == .descriptors, let id = item.installationBackupID else { throw RunnerError(localized: "削除できるのは、このアプリで追加した壁紙だけです。") }
        let path = try WallpaperPaths.normalized(item.path)
        try validateWallpaperDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let current = try withReadAccess(path: path, directory: true) { try FileBackupStore.Snapshot(path: path) }
        let record = try FileBackupStore(root: backupRoot).record(id: id)
        guard current.device == item.snapshot.device, current.inode == item.snapshot.inode,
              WallpaperLibraryReader.owns(record, path: path, snapshot: current) else {
            throw RunnerError(localized: "追加した壁紙の記録と一致しません。一覧を更新してください。別の壁紙は削除しません。")
        }
    }

    private func validateWallpaperDirectory(_ rawPath: String) throws {
        let path = try WallpaperPaths.normalized(rawPath)
        try WallpaperPaths.validateDestination(path)
        let marker = "/" + WallpaperPaths.store + "/"
        guard let range = path.range(of: marker) else { throw RunnerError(localized: "壁紙の追加先が不正です。") }
        let container = String(path[..<range.lowerBound])
        try validateWallpaperAncestors(path, container: container)
    }

    private func validateWallpaperAncestors(_ path: String, container: String) throws {
        // Refuse existing symlinks along the container-relative destination.
        for current in try WallpaperPaths.directoryAncestors(path, container: container) {
            let snapshot = try withReadAccess(path: current, directory: true) { try FileBackupStore.Snapshot(path: current) }
            guard snapshot.isDirectory else { throw RunnerError(localized: "壁紙の追加先にリンクまたは非フォルダがあります。") }
        }
    }

    private func performManagedWallpaperChange(_ change: PendingWallpaperChange, operation: FileWriteOperation,
                                              source: URL, destination: URL?, title: String) throws -> FileWriteReceipt {
        let store = FileBackupStore(root: backupRoot)
        let refreshURL = URL(fileURLWithPath: change.refresh.path)
        try store.protect(source)
        if let destination { try store.protect(destination) }
        try store.protect(refreshURL)
        let root = refreshURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let result = try WallpaperWriteTransaction.perform(operation: operation, source: source, destination: destination, change: change,
            store: store, preflight: {
                if let removal = change.removal { try self.validateManagedWallpaper(removal) }
                else {
                    guard case .addWallpaper(_, let directory) = operation, let destination else { throw RunnerError(localized: "壁紙の操作が不正です。") }
                    try self.validateWallpaperDirectory(directory)
                    try self.requireAbsent(destination)
                }
                let current = try self.wallpaperRefresh(container: root)
                guard current.original == change.refresh.original else { throw RunnerError(localized: "壁紙の設定が更新されました。操作をやり直してください。") }
                try self.withReadAccess(path: change.refresh.path) {
                    let fd = open(change.refresh.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    close(fd)
                }
            }, backup: { operation, source, destination, metadata in
                let directory = try FileBackupStore.Snapshot(path: source.path).isDirectory
                return try self.withReadAccess(path: source.path, directory: directory) {
                    try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
                }
            }, writePrimary: { backup in
                if let removal = change.removal {
                    try self.validateManagedWallpaper(removal)
                    try self.files.removeItem(at: source)
                } else {
                    let directory = destination!.deletingLastPathComponent().path
                    try self.validateWallpaperDirectory(directory)
                    try self.requireAbsent(destination!)
                    try self.files.copyItem(at: backup.payload, to: destination!)
                }
            }, writeRefresh: { backup in
                try self.validateWallpaperAncestors(refreshURL.deletingLastPathComponent().path, container: root)
                try self.saveBackedUpData(path: change.refresh.path, data: change.refresh.data, original: change.refresh.original, snapshot: backup.snapshot["."]!)
            })
        return FileWriteReceipt(backupDirectory: result.directory, title: title)
    }

    // The only mutation entry point. One-use requests are bound to the operation
    // presented in the confirmation alert.
    func commitWrite(_ request: FileWriteRequest, userConsented: Bool) throws -> FileWriteReceipt {
        if let plan = pendingKeypadChanges.removeValue(forKey: request.id) {
            return try withAccessSession {
                try KeypadWriteTransaction.execute(plan.entries, store: FileBackupStore(root: backupRoot), userConsented: userConsented,
                    validate: { entry in
                        let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
                        try self.validateKeypadDirectory(directory, expected: entry.directory)
                        try self.withReadAccess(path: entry.path) {
                            let fd = open(entry.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            close(fd)
                        }
                    }, backup: { entry in
                        let url = URL(fileURLWithPath: entry.file.path)
                        return try self.withReadAccess(path: url.path) {
                            try FileBackupStore(root: self.backupRoot).prepare(operation: .replaceKeypad(path: url.path), source: url, destination: url)
                        }
                    }, write: { entry, backup in
                        let original = try StableFileReader.read(path: backup.payload.path, maximumBytes: KeypadImage.maximumBytes) { $0 }
                        try self.saveBackedUpData(path: entry.file.path, data: entry.data, original: original,
                                                 snapshot: entry.file.snapshot, maximumBytes: KeypadImage.maximumBytes)
                    })
            }
        }
        return try withAccessSession { try performConfirmedWrite(request, userConsented: userConsented) }
    }

    private func performConfirmedWrite(_ request: FileWriteRequest, userConsented: Bool) throws -> FileWriteReceipt {
        guard let operation = pendingWrites.removeValue(forKey: request.id) else { throw RunnerError(localized: "確認は無効または使用済みです。操作をやり直してください。") }
        let wallpaperChange = pendingWallpaperChanges.removeValue(forKey: request.id)
        let wallpaperMetadata = pendingWallpaperRefreshes.removeValue(forKey: request.id) ?? wallpaperChange?.metadata
        defer {
            if let directory = stagedWriteDirectories.removeValue(forKey: request.id) { try? files.removeItem(at: directory) }
        }
        guard userConsented else { throw RunnerError(localized: "操作ごとのユーザー同意が必要です。") }
        try Task.checkCancellation()
        let (source, destination) = try writePaths(operation)
        if let removal = wallpaperChange?.removal { try validateManagedWallpaper(removal) }
        if case .addWallpaper(_, let directory) = operation {
            try validateWallpaperDirectory(directory)
            guard let source, try FileBackupStore.Snapshot(path: source.path).isDirectory else { throw RunnerError(localized: "壁紙の追加元が通常のフォルダではありません。") }
        }
        guard request.sourcePath == source?.path, request.destinationPath == destination?.path else {
            throw RunnerError(localized: "確認後に操作対象の状態が変わりました。確認をやり直してください。")
        }
        if let wallpaperChange, let source {
            return try performManagedWallpaperChange(wallpaperChange, operation: operation, source: source, destination: destination, title: request.title)
        }
        let scoped: Bool
        if case .importFile = operation { scoped = source?.startAccessingSecurityScopedResource() == true }
        else { scoped = false }
        defer { if scoped { source?.stopAccessingSecurityScopedResource() } }
        let store = FileBackupStore(root: backupRoot)
        if let source { try store.protect(source) }
        if let destination { try store.protect(destination) }
        if let source {
            _ = try withReadAccess(path: source.path) { try FileBackupStore.Snapshot(path: source.path) }
        }
        if let destination, destination != source {
            // Acquire only on a read denial, before any write or backup is attempted.
            _ = try withReadAccess(path: destination.deletingLastPathComponent().path, directory: true) {
                try files.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
            }
            try requireAbsent(destination)
        }
        if case let .saveText(_, text, original) = operation {
            guard text.utf8.count <= previewLimit else { throw RunnerError(localized: "テキスト保存は1 MiBまでです。") }
            guard try readText(path: source!.path) == original else { throw RunnerError(localized: "ファイルが外部で変更されました。開き直してください。") }
        }
        if case let .savePropertyList(_, data, original) = operation {
            let updated = try PropertyListValue.decode(data), previous = try PropertyListValue.decode(original)
            guard updated.format == previous.format else { throw RunnerError(localized: "元のPlist形式は変更できません。") }
            let current = try withReadAccess(path: source!.path) {
                try StableFileReader.read(path: source!.path, maximumBytes: DocumentPreview.maximumPlistBytes) { $0 }
            }
            guard current == original else { throw RunnerError(localized: "Plistが外部で変更されました。開き直してください。") }
        }
        // A readable file is not necessarily writable. Probe without truncating
        // and acquire on a write-open denial before creating the backup/mutating.
        if let source {
            switch operation {
            case .saveText, .savePropertyList, .restoreBackup:
                if try FileBackupStore.Snapshot(path: source.path).isRegular {
                    try withReadAccess(path: source.path) {
                        let fd = open(source.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        close(fd)
                    }
                }
            default: break
            }
        }
        let restorationRecord: FileBackupRecord?
        if case .restoreBackup(let id) = operation {
            let record = try store.record(id: id)
            switch try record.restoration() {
            case .original:
                try store.verifyPayload(record)
                if let source {
                    guard try FileBackupStore.Snapshot(path: source.path).isRegular, record.manifest.entries["."]?.isRegular == true else {
                        throw RunnerError(localized: "既存フォルダとの結合・置換や型の変更は行いません。別の場所へ退避してから復元してください。")
                    }
                }
            case .removeCreated:
                guard let source else { throw RunnerError(localized: "取り消す項目がありません。") }
                let state = try withReadAccess(path: source.path, directory: record.outcome?.snapshot?["."]?.isDirectory == true) { try store.snapshot(source) }
                guard state == record.outcome?.snapshot else {
                    throw RunnerError(localized: "作成後に項目が変更されています。新しいデータを削除しないため復元を中止しました。")
                }
            }
            restorationRecord = record
        } else { restorationRecord = nil }
        // Nothing below this line runs unless a complete persistent backup exists.
        let backup: FileBackupStore.Backup
        if let source {
            let directory = try FileBackupStore.Snapshot(path: source.path).isDirectory
            backup = try withReadAccess(path: source.path, directory: directory) {
                try store.prepare(operation: operation, source: source, destination: destination, wallpaper: wallpaperMetadata)
            }
        } else { backup = try store.prepare(operation: operation, source: nil, destination: destination, wallpaper: wallpaperMetadata) }
        do {
            try Task.checkCancellation()
            if let source, try store.snapshot(source) != backup.snapshot { throw RunnerError(localized: "バックアップ後に元データが変更されました。操作は実行しません。") }
            if let destination, destination != source { try requireAbsent(destination) }
            switch operation {
            case let .saveText(_, text, original):
                try saveBackedUpData(path: source!.path, data: Data(text.utf8), original: Data(original.utf8), snapshot: backup.snapshot["."]!)
            case let .savePropertyList(_, data, original):
                try saveBackedUpData(path: source!.path, data: data, original: original, snapshot: backup.snapshot["."]!)
            case .createFolder:
                try files.createDirectory(at: destination!, withIntermediateDirectories: false)
            case .rename:
                try files.moveItem(at: source!, to: destination!)
            case .delete:
                try files.removeItem(at: source!)
            case .importFile, .addWallpaper:
                if case .addWallpaper(_, let directory) = operation { try validateWallpaperDirectory(directory) }
                try files.copyItem(at: backup.payload, to: destination!)
            case .restoreBackup:
                let record = restorationRecord!
                switch try record.restoration() {
                case .original:
                    if let source { try restoreFile(from: record.payload, to: source.path, snapshot: backup.snapshot["."]!) }
                    else { try files.copyItem(at: record.payload, to: destination!) }
                case .removeCreated:
                    try files.removeItem(at: source!)
                }
            case .replaceKeypad:
                throw RunnerError(localized: "キーパッドの変更確認が無効です。")
            }
            try store.finish(backup, changedPath: destination?.path ?? source?.path, succeeded: true)
        } catch {
            try? store.finish(backup, changedPath: destination?.path ?? source?.path, succeeded: false)
            throw RunnerError(localized: "\(String(describing: error.localizedDescription))\nバックアップ: \(String(describing: backup.directory.path))")
        }
        return FileWriteReceipt(backupDirectory: backup.directory, title: request.title)
    }

    private func requireAbsent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw RunnerError(localized: "同名の項目が存在します。上書きしません。") }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func saveBackedUpData(path: String, data: Data, original: Data, snapshot: FileBackupStore.Snapshot,
                                  maximumBytes: Int = 1_048_576) throws {
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == snapshot.device, opened.st_ino == snapshot.inode,
              try FileBackupStore.Snapshot(path: path) == snapshot,
              (try handle.read(upToCount: maximumBytes + 1) ?? Data()) == original else {
            throw RunnerError(localized: "保存前にファイルが変更・置換されました。操作を中止しました。")
        }
        // Keep inode, ownership, permissions and xattrs of the original file.
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }

    private func restoreFile(from original: URL, to path: String, snapshot: FileBackupStore.Snapshot) throws {
        try StableFileReader.withFile(path: original.path, maximumBytes: Int(FileBackupStore.maximumBytes)) { input, size in
            let fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == snapshot.device, info.st_ino == snapshot.inode,
                  info.st_mode & S_IFMT == S_IFREG, try FileBackupStore.Snapshot(path: path) == snapshot else {
                throw RunnerError(localized: "復元前に対象が変更・置換されました。")
            }
            while true {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: 1_048_576) ?? Data()
                if bytes.isEmpty { break }
                try output.write(contentsOf: bytes)
            }
            try output.truncate(atOffset: UInt64(size))
            try output.synchronize()
        }
    }

    static func queryError(_ code: Int64) -> String {
        let detail: String
        switch code {
        case -1: detail = L("App Groupにアクセスできません。Apple IDでサイドロードし直してください。")
        case -2: detail = L("必要なprivate APIを解決できません。この環境は非対応です。")
        case -3: detail = L("コンテナクエリの作成に失敗しました。")
        case -4: detail = L("App Group Cachesのシンボリックリンク作成に失敗しました。")
        case -5: detail = L("containermanagerdが拒否しました。親パスではなく個別UUIDのパスを指定してください。")
        case -6: detail = L("カーネルがSandbox Extensionの発行を拒否しました。")
        case -8: detail = L("権限トークンは発行されましたが、両方のクエリフラグでSandboxに拒否されました。")
        case -255: detail = L("パスを確認できません（存在しないか、現在の権限でstatできません）。")
        default: detail = L("Sandbox Extensionの取得に失敗しました。")
        }
        return L("worse_query \(String(describing: code)): \(String(describing: detail))")
    }
}
