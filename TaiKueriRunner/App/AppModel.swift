import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selectedTab = AppTab.home
    private(set) var logs: [LogEntry] = []
    private(set) var busy = false
    var errorMessage: String?
    var browserPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    var browserRevision = 0
    private(set) var fileWriteRevision = 0
    let accessManager = FileAccessManager()

    // Middle layer: shared across screens so a completed read survives tab and
    // screen changes. The underlying services keep one lightweight snapshot
    // per group for the whole app session; only an explicit refresh re-reads.
    let applicationCatalog = ApplicationCatalogModel()
    let appGroupScan = AppGroupScanModel()

    @ObservationIgnored lazy var applicationCatalogService = ApplicationCatalogService(files: accessManager)
    @ObservationIgnored lazy var keypadService = KeypadLibraryWorker(files: accessManager)
    @ObservationIgnored lazy var appGroupScanner = AppGroupScanner(files: accessManager)
    @ObservationIgnored let wallpaperLibrary = WallpaperLibraryModel()

    private static let launchServicesStoreKey = "launchServicesStorePath"

    var canAcquireAccess: Bool {
        RuntimeSupport.isReportedSupported(ProcessInfo.processInfo.operatingSystemVersion) && RuntimeSupport.appGroup != nil
    }

    init() {
        log(L("TaiKueriRunner起動。"))
        log(L("署名のApp Groups: \(String(describing: RuntimeSupport.entitledGroupIDs.isEmpty ? L("なし（未付与または取得不可）") : RuntimeSupport.entitledGroupIDs.joined(separator: ", ")))"))
        if let group = RuntimeSupport.appGroup {
            log(L("使用するApp Group: \(String(describing: group.identifier))"))
        } else {
            log(L("利用可能なApp Groupがありません。App Groupsを付与するAltStore・SideStore・Sideloadly等で再署名してください。"), error: true)
        }
        Task {
            let result = await accessManager.purgeOrphanedStagingFiles()
            guard result.removedItems > 0 || result.failedItems > 0 else { return }
            let bytes = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
            if result.failedItems > 0 {
                log(L("起動時: 古い一時ファイル\(String(describing: result.removedItems))件（\(String(describing: bytes))）を削除し、\(String(describing: result.failedItems))件を削除できませんでした。"), error: true)
            } else {
                log(L("起動時: 古い一時ファイル\(String(describing: result.removedItems))件（\(String(describing: bytes))）を削除しました。"))
            }
        }
    }

    func log(_ message: String, error: Bool = false) {
        logs.append(.init(message: message, isError: error))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        log(error.localizedDescription, error: true)
    }

    func run(_ title: String, operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await operation()
                log(title)
            } catch { report(error) }
        }
    }

    // MARK: - Middle-layer data access

    /// Loads the application list from the session cache when possible.
    /// Use `forceRefresh` only for an explicit user action.
    @discardableResult
    func loadApplications(forceRefresh: Bool = false, freshSearch: Bool = false,
                          progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ApplicationCatalogSnapshot {
        let stored = UserDefaults.standard.string(forKey: Self.launchServicesStoreKey) ?? ""
        let snapshot = try await applicationCatalogService.load(
            cachedPath: stored.isEmpty ? nil : stored,
            group: RuntimeSupport.groupID,
            freshSearch: freshSearch,
            forceRefresh: forceRefresh,
            progress: progress
        )
        UserDefaults.standard.set(snapshot.sourcePath, forKey: Self.launchServicesStoreKey)
        return snapshot
    }

    /// Loads applications and App Groups together for the middle and top
    /// layers. The App Group scan reuses its session snapshot unless
    /// `forceRefresh` is set.
    func scanAppGroups(forceRefresh: Bool = false,
                       catalogProgress: @escaping @Sendable (String) async -> Void = { _ in },
                       progress: @escaping @Sendable (AppGroupScanSnapshot) async -> Void = { _ in }) async throws -> AppGroupScanSnapshot {
        var source: ApplicationCatalogSnapshot?
        var catalogIssue: String?
        do {
            source = try await loadApplications(forceRefresh: forceRefresh, progress: catalogProgress)
            if let source { applicationCatalog.adopt(source) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            catalogIssue = L("アプリDBを読み取れません。\n\(String(describing: error.localizedDescription))")
        }
        return try await appGroupScanner.scan(
            knownPaths: [],
            catalog: source?.catalog,
            catalogIssue: catalogIssue,
            catalogLoadedAt: source?.loadedAt,
            forceRefresh: forceRefresh,
            progress: progress
        )
    }

    /// Explicit refresh from the Applications screen: the App Group list is
    /// based on the same DB, so discard both caches before reading again.
    @discardableResult
    func refreshApplications(freshSearch: Bool,
                             progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> ApplicationCatalogSnapshot {
        await invalidateApplicationCaches()
        appGroupScan.invalidate()
        return try await loadApplications(freshSearch: freshSearch, progress: progress)
    }

    func invalidateApplicationCaches() async {
        await applicationCatalogService.invalidateCache()
        await appGroupScanner.invalidateCache()
    }

    func releaseAll() {
        run(L("すべてのSandbox Extensionとフォルダ選択権限を解放しました。")) {
            await self.accessManager.releaseAll()
        }
    }

    func endAccessSessions() async {
        await accessManager.releaseAll()
        log(L("バックグラウンド移行: アクセス状態と未実行の確認を破棄しました。"))
    }

    func didWrite(_ receipt: FileWriteReceipt) {
        log(L("\(String(describing: receipt.title))完了。バックアップ: \(String(describing: receipt.backupDirectory.path))"))
        browserRevision += 1
        fileWriteRevision += 1
    }

    func browse(_ path: String) {
        browserPath = path
        browserRevision += 1
        selectedTab = .files
    }

    func clearLogs() { logs.removeAll() }

    var logText: String {
        logs.map { "[\($0.date.formatted(date: .omitted, time: .standard))] \($0.isError ? "ERROR " : "")\($0.message)" }.joined(separator: "\n")
    }
}
