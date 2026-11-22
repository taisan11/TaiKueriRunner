import Foundation
import ImageIO

enum WallpaperDisplay {
    static func provider(_ id: String) -> String {
        switch id {
        case "com.apple.WallpaperKit.CollectionsPoster": L("コレクション")
        case "com.apple.MercuryPoster": L("アニメーション")
        case "com.apple.PhotosUIPrivate.PhotosPosterProvider": L("写真・ビデオ")
        case let value where value.contains("GradientPoster"): L("カラー")
        case let value where value.contains("ClockPoster"): L("時計")
        case let value where value.contains("WeatherPoster"): L("天気")
        default: id.components(separatedBy: ".").last ?? id
        }
    }

    static func title(asset: String?, identifier: String, fallback: String) -> String {
        if let asset {
            let name = String(asset.dropLast(".wallpaper".count))
                .replacingOccurrences(of: #"^\d+\."#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"-\d+w-\d+h.*$"#, with: "", options: .regularExpression)
            if !name.isEmpty { return name }
        }
        if Int(identifier) == nil, UUID(uuidString: identifier) == nil, !identifier.isEmpty { return String(identifier.prefix(100)) }
        if UUID(uuidString: fallback) == nil, !fallback.isEmpty { return String(fallback.prefix(100)) }
        return L("壁紙 ") + String(fallback.prefix(8))
    }

    static func preview(in paths: [String]) -> String? {
        paths.filter { ["png", "jpg", "jpeg", "heic", "heif"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted {
                func rank(_ path: String) -> Int {
                    let name = (path as NSString).lastPathComponent.lowercased()
                    if name.contains("thumbnail") || name.contains("preview") { return 0 }
                    if name.contains("background") || name == "proxy.heic" { return 1 }
                    return 2
                }
                return rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1)
            }.first
    }
}

enum WallpaperThumbnail {
    static let maximumBytes = 16 * 1024 * 1024
    static func make(_ data: Data) throws -> Data? {
        try Task.checkCancellation()
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try Task.checkCancellation()
        return output as Data
    }
}

struct WallpaperBackupMetadata: Codable, Sendable {
    let changeID: UUID
    let title: String
    let package: String?
    let isRefresh: Bool
}

struct InstalledWallpaper: Identifiable, Sendable {
    enum Location: String, CaseIterable, Sendable {
        case descriptors, staticdescriptors, suggestionDescriptors, configurations
        var isGallery: Bool { self != .configurations }
    }
    let path: String
    let provider: String
    let location: Location
    let title: String
    let identifier: String
    let previewPath: String?
    let snapshot: FileBackupStore.Snapshot
    let installationBackupID: String?
    var id: String { path }
    var isManaged: Bool { installationBackupID != nil }
    var isPhotoOrVideo: Bool { provider == "com.apple.PhotosUIPrivate.PhotosPosterProvider" }

    func isVisible(showPhotosAndVideos: Bool = false) -> Bool { showPhotosAndVideos || !isPhotoOrVideo }
}

struct WallpaperLibrarySnapshot: Sendable {
    let items: [InstalledWallpaper]
    let unreadableCount: Int
    let latestChange: Date?
    let refreshRequired: Bool
    var issues: [WallpaperReadIssue] = []
    var diagnostics: WallpaperLibraryDiagnostics? = nil
}

struct WallpaperReadIssue: Sendable {
    let operation: String
    let path: String
    let message: String
    var summary: String { L("\(String(describing: operation)): \(String(describing: path))\n\(String(describing: message))") }

    init(operation: String, path: String, error: Error) {
        self.operation = operation
        self.path = path
        let error = error as NSError
        message = "\(error.localizedDescription) [\(error.domain):\(error.code)]"
    }
}

// Dependencies keep discovery testable on a host without opening the device DB.
struct WallpaperLibraryReader {
    let list: (String) async throws -> [FileEntry]
    let read: (String, Int) async throws -> Data
    var inspect: (String) async throws -> FileBackupStore.Snapshot = { try FileBackupStore.Snapshot(path: $0) }
    private struct Limit: LocalizedError {
        var errorDescription: String? { L("壁紙一覧の上限（30,000項目）を超えています。") }
    }

    func load(container: String, backups: [FileBackupRecord],
              onProgress: @Sendable (WallpaperLibrarySnapshot) async -> Void = { _ in },
              isolation: isolated (any Actor)? = #isolation) async throws -> WallpaperLibrarySnapshot {
        let extensions = container + "/" + WallpaperPaths.store + "/Extensions"
        let normalizedExtensions = try WallpaperPaths.normalized(extensions)
        let normalizedPreferences = try WallpaperPaths.normalized(container + "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
        var visited = 0, unreadable = 0
        var issues: [WallpaperReadIssue] = []
        var diagnostics = WallpaperLibraryDiagnostics(container: container, extensionsPath: extensions)
        let changes = backups.filter { record in
            guard record.outcome?.succeeded == true, let metadata = record.manifest.wallpaper, !metadata.isRefresh else { return false }
            let path = record.manifest.destinationPath ?? record.manifest.sourcePath ?? ""
            return (try? WallpaperPaths.normalized(path))?.hasPrefix(normalizedExtensions + "/") == true
        }
        let latest = changes.max { $0.manifest.created < $1.manifest.created }
        let refreshes = backups.filter { $0.manifest.wallpaper?.isRefresh == true && $0.outcome?.succeeded == true &&
            $0.manifest.sourcePath.flatMap { try? WallpaperPaths.normalized($0) } == normalizedPreferences }
        let needsRefresh = latest.map { change in
            !refreshes.contains { $0.manifest.created >= change.manifest.created }
        } ?? false
        let latestChange = ([latest?.manifest.created] + refreshes.map { Optional($0.manifest.created) }).compactMap { $0 }.max()
        func record(_ error: Error, operation: String, path: String, isolation: isolated (any Actor)? = #isolation) {
            unreadable += 1
            diagnostics.count("read.failures")
            diagnostics.record(WallpaperReadIssue(operation: operation, path: path, error: error).summary)
            if issues.count < 20 { issues.append(WallpaperReadIssue(operation: operation, path: path, error: error)) }
        }
        func attributes(_ path: String, isolation: isolated (any Actor)? = #isolation) async throws -> FileBackupStore.Snapshot? {
            try Task.checkCancellation()
            do { return try await inspect(path) }
            catch is CancellationError { throw CancellationError() }
            catch where Self.isMissing(error) {
                // Unlike optional location folders, these children were just
                // enumerated. ENOENT here is not evidence of an empty gallery.
                diagnostics.count("attribute.enumeratedButMissing")
                record(error, operation: L("一覧に存在する項目の属性取得"), path: path)
                return nil
            }
            catch { record(error, operation: L("属性の取得"), path: path); return nil }
        }
        func contents(_ path: String, isolation: isolated (any Actor)? = #isolation) async throws -> [FileEntry] {
            try Task.checkCancellation()
            let entries = try await list(path)
            try Task.checkCancellation()
            visited += entries.count
            diagnostics.count("enumerated.entries", by: entries.count)
            guard visited <= 30_000 else { throw Limit() }
            let relative = path.hasPrefix(extensions + "/") ? String(path.dropFirst(extensions.count + 1)) : ""
            if path == extensions || relative.split(separator: "/").count <= 2 {
                diagnostics.listing(path: path, names: entries.map(\.name).sorted())
            }
            return entries.sorted { $0.name < $1.name }
        }
        func optionalContents(_ path: String, isolation: isolated (any Actor)? = #isolation) async throws -> [FileEntry] {
            do { return try await contents(path) }
            catch is CancellationError { throw CancellationError() }
            catch is Limit { throw RunnerError(localized: "壁紙一覧の上限（30,000項目）を超えています。") }
            catch where Self.isMissing(error) {
                diagnostics.count("optionalDirectory.missing")
                diagnostics.record("MISSING \(path)")
                return []
            }
            catch { record(error, operation: L("フォルダの一覧取得"), path: path); return [] }
        }
        let records = backups.filter { $0.manifest.operationKind == "addWallpaper" && $0.outcome?.succeeded == true }
        var items: [InstalledWallpaper] = []
        var lastProgress = Date.timeIntervalSinceReferenceDate
        // Read-only context for diagnosing a stale/empty structure-61 store.
        // Seeing another version here never changes the write destination.
        _ = try await optionalContents(container + "/Library/Application Support/PRBPosterExtensionDataStore")
        // Directory enumeration can return names while metadata prefetching is
        // denied. Never interpret FileEntry's fallback `isDirectory == false`
        // as proof that a provider/descriptor is not a directory.
        let providers: [FileEntry]
        do { providers = try await contents(extensions) }
        catch is CancellationError { throw CancellationError() }
        catch {
            record(error, operation: L("壁紙プロバイダー一覧の取得"), path: extensions)
            throw RunnerError(L("壁紙の読み取り先を確認できませんでした。\n\n") + diagnostics.report)
        }
        diagnostics.count("provider.entries", by: providers.count)
        for provider in providers {
            guard Self.validProvider(provider.name) else {
                diagnostics.count("provider.rejectedName")
                diagnostics.record("SKIP provider-name \(String(reflecting: provider.name))")
                continue
            }
            diagnostics.count("provider.validNames")
            guard let providerInfo = try await attributes(provider.path) else { continue }
            guard providerInfo.isDirectory else {
                diagnostics.count("provider.notDirectory")
                diagnostics.record("SKIP provider-type mode=\(String(providerInfo.mode, radix: 8)) \(provider.path)")
                continue
            }
            diagnostics.count("provider.directories")
            _ = try await optionalContents(provider.path) // Record the actual layout, including previously unhandled folders.
            for location in InstalledWallpaper.Location.allCases {
                let directory = provider.path + "/" + location.rawValue
                let candidates = try await optionalContents(directory)
                diagnostics.count("candidate.\(location.rawValue)", by: candidates.count)
                for item in candidates {
                    guard UUID(uuidString: item.name) != nil else {
                        diagnostics.count("candidate.rejectedID.\(location.rawValue)")
                        diagnostics.record("SKIP wallpaper-id \(item.path)")
                        continue
                    }
                    guard items.count < 2_000 else { throw RunnerError(localized: "壁紙一覧は2,000件までです。") }
                    guard let root = try await attributes(item.path) else { continue }
                    guard root.isDirectory else {
                        diagnostics.count("candidate.notDirectory.\(location.rawValue)")
                        diagnostics.record("SKIP wallpaper-type mode=\(String(root.mode, radix: 8)) \(item.path)")
                        continue
                    }
                    let managed = location == .descriptors ? records.first(where: { Self.owns($0, path: item.path, snapshot: root) }) : nil
                    var identifier = ""
                    do {
                        let bytes = try await read(item.path + "/com.apple.posterkit.provider.descriptor.identifier", 4096)
                        identifier = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if identifier.rangeOfCharacter(from: .controlCharacters) != nil { identifier = "" }
                    } catch is CancellationError { throw CancellationError() }
                    catch { record(error, operation: L("壁紙名の読み取り"), path: item.path + "/com.apple.posterkit.provider.descriptor.identifier") }
                    var versions: [FileEntry] = []
                    for version in try await optionalContents(item.path + "/versions") where Int(version.name).map({ $0 >= 0 }) == true {
                        if try await attributes(version.path)?.isDirectory == true { versions.append(version) }
                    }
                    var assets: [String] = [], images: [String] = []
                    if let version = versions.max(by: { (Int($0.name) ?? 0) < (Int($1.name) ?? 0) }) {
                        func visit(_ path: String, depth: Int, isolation: isolated (any Actor)? = #isolation) async throws {
                            guard depth <= 16 else { return }
                            for child in try await optionalContents(path) {
                                guard let info = try await attributes(child.path), info.isDirectory || info.isRegular else { continue }
                                if child.name.hasSuffix(".wallpaper") { assets.append(child.name) }
                                if info.isDirectory { try await visit(child.path, depth: depth + 1) }
                                else if info.size <= WallpaperThumbnail.maximumBytes { images.append(child.path) }
                            }
                        }
                        try await visit(version.path + "/contents", depth: 0)
                    }
                    let title = managed?.manifest.wallpaper?.title ??
                        WallpaperDisplay.title(asset: assets.first, identifier: identifier, fallback: item.name)
                    items.append(InstalledWallpaper(path: item.path, provider: provider.name, location: location, title: title,
                                                    identifier: identifier, previewPath: WallpaperDisplay.preview(in: images),
                                                    snapshot: root, installationBackupID: managed?.id))
                    diagnostics.count("accepted.\(location.rawValue)")
                    let now = Date.timeIntervalSinceReferenceDate
                    if items.count == 1 || items.count.isMultiple(of: 8) || now - lastProgress >= 0.15 {
                        try Task.checkCancellation()
                        await onProgress(WallpaperLibrarySnapshot(items: items, unreadableCount: unreadable,
                            latestChange: latestChange, refreshRequired: needsRefresh, issues: issues, diagnostics: diagnostics))
                        try Task.checkCancellation()
                        lastProgress = now
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard !items.isEmpty || unreadable == 0 else {
            throw RunnerError(L("壁紙の読み取りに失敗したため、一覧を表示できません。壁紙が0件と確認できたわけではありません。\n\n") +
                              issues.map(\.summary).joined(separator: "\n\n") + "\n\n" + diagnostics.report)
        }
        return WallpaperLibrarySnapshot(items: items.sorted {
            if $0.isManaged != $1.isManaged { return $0.isManaged }
            return $0.title == $1.title ? $0.path < $1.path : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }, unreadableCount: unreadable,
           latestChange: latestChange,
           refreshRequired: needsRefresh, issues: issues, diagnostics: diagnostics)
    }

    static func validProvider(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") && name.utf8.count <= 200 &&
            name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return value.code == Int(ENOENT) }
        if value.domain == NSCocoaErrorDomain &&
            (value.code == CocoaError.fileReadNoSuchFile.rawValue || value.code == CocoaError.fileNoSuchFile.rawValue) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isMissing(underlying) }
        return false
    }

    static func owns(_ record: FileBackupRecord, path: String, snapshot: FileBackupStore.Snapshot) -> Bool {
        guard record.manifest.operationKind == "addWallpaper", record.outcome?.succeeded == true,
              let destination = record.manifest.destinationPath,
              let expectedPath = try? WallpaperPaths.normalized(destination),
              let actualPath = try? WallpaperPaths.normalized(path), expectedPath == actualPath,
              let changedPath = record.outcome?.changedPath,
              (try? WallpaperPaths.normalized(changedPath)) == expectedPath,
              let original = record.outcome?.snapshot?["."], original.isDirectory, snapshot.isDirectory else { return false }
        return original.device == snapshot.device && original.inode == snapshot.inode
    }
}

struct WallpaperRefresh: Sendable {
    let path: String
    let original: Data
    let data: Data
}

struct PendingWallpaperChange: Sendable {
    let refresh: WallpaperRefresh
    let metadata: WallpaperBackupMetadata
    let removal: InstalledWallpaper?
}

enum WallpaperWriteTransaction {
    // Host tests can exercise the same two-phase executor with local paths.
    // Device path validation and permission acquisition remain with the manager.
    static func perform(operation: FileWriteOperation, source: URL, destination: URL?, change: PendingWallpaperChange,
                        store: FileBackupStore, preflight: () throws -> Void,
                        backup: (FileWriteOperation, URL, URL?, WallpaperBackupMetadata) throws -> FileBackupStore.Backup,
                        writePrimary: (FileBackupStore.Backup) throws -> Void,
                        writeRefresh: (FileBackupStore.Backup) throws -> Void) throws -> FileBackupStore.Backup {
        try preflight()
        let primary = try backup(operation, source, destination, change.metadata)
        let refreshURL = URL(fileURLWithPath: change.refresh.path)
        let refreshBackup: FileBackupStore.Backup
        do {
            refreshBackup = try backup(.savePropertyList(path: change.refresh.path, data: change.refresh.data, original: change.refresh.original),
                                      refreshURL, refreshURL,
                                      WallpaperBackupMetadata(changeID: change.metadata.changeID, title: change.metadata.title,
                                                              package: change.metadata.package, isRefresh: true))
        } catch {
            try? store.finish(primary, changedPath: nil, succeeded: false)
            throw RunnerError(localized: "バックアップを準備できなかったため、壁紙は変更していません。\n\(String(describing: error.localizedDescription))\nバックアップ: \(String(describing: primary.directory.path))")
        }
        var primarySucceeded = false
        do {
            try Task.checkCancellation()
            try preflight()
            guard try store.snapshot(source) == primary.snapshot,
                  try store.snapshot(refreshURL) == refreshBackup.snapshot else {
                throw RunnerError(localized: "バックアップ後に壁紙または表示設定が変更されました。操作をやり直してください。")
            }
            try writePrimary(primary)
            try store.finish(primary, changedPath: destination?.path ?? source.path, succeeded: true)
            primarySucceeded = true
            try writeRefresh(refreshBackup)
            try store.finish(refreshBackup, changedPath: change.refresh.path, succeeded: true)
            return primary
        } catch {
            if !primarySucceeded { try? store.finish(primary, changedPath: destination?.path ?? source.path, succeeded: false) }
            try? store.finish(refreshBackup, changedPath: change.refresh.path, succeeded: false)
            let note = primarySucceeded ?
                L("壁紙の変更は完了しましたが、表示の更新準備に失敗しました。壁紙画面の「表示を更新」から再試行してください。\n") : ""
            throw RunnerError(localized: "\(String(describing: note))\(String(describing: error.localizedDescription))\nバックアップ: \(String(describing: primary.directory.path))\n表示設定のバックアップ: \(String(describing: refreshBackup.directory.path))")
        }
    }
}
