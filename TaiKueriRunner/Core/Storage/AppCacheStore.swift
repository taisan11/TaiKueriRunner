import Foundation

struct AppCacheUsage: Equatable, Sendable {
    let temporaryBytes: Int64
    let temporaryItems: Int
    let cacheBytes: Int64
    let cacheItems: Int

    var totalBytes: Int64 { temporaryBytes + cacheBytes }
    var totalItems: Int { temporaryItems + cacheItems }
}

struct AppCacheCleanupResult: Equatable, Sendable {
    let freedBytes: Int64
    let removedItems: Int
    let failedItems: Int
}

// Cleans only this app's private temporary staging directories and Library/Caches.
// iOS-managed areas such as Library/SplashBoard are never touched.
struct AppCacheStore: Sendable {
    static let stagingPrefixes = [
        "ApplicationDataExport-",
        "AppGroupDataExport-",
        "DocumentPreview-",
        "SQLitePreview-",
        "LINEDataPreview-",
        "LINEMediaShare-",
        "WallpaperImport-",
        "KeypadExport-"
    ]

    let temporaryRoot: URL
    let cachesRoot: URL

    func usage(activeDirectories: Set<URL> = []) -> AppCacheUsage {
        let staging = stagingDirectories(activeDirectories: activeDirectories, olderThan: nil)
        let cache = cacheEntries()
        return AppCacheUsage(
            temporaryBytes: staging.reduce(Int64(0)) { $0 + FileUsage.bytes(at: $1) },
            temporaryItems: staging.count,
            cacheBytes: cache.reduce(Int64(0)) { $0 + FileUsage.bytes(at: $1) },
            cacheItems: cache.count
        )
    }

    func cleanup(activeDirectories: Set<URL> = []) -> AppCacheCleanupResult {
        cleanup(activeDirectories: activeDirectories, stagingAge: nil, includeCaches: true)
    }

    // Launch-time recovery for directories left behind by force-quit or a crash.
    // A recent directory is kept in case an external share is still reading it.
    func purgeStaging(olderThan age: TimeInterval = 24 * 60 * 60,
                      activeDirectories: Set<URL> = []) -> AppCacheCleanupResult {
        cleanup(activeDirectories: activeDirectories, stagingAge: max(0, age), includeCaches: false)
    }

    static func isStagingName(_ name: String) -> Bool {
        for prefix in stagingPrefixes where name.hasPrefix(prefix) {
            return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        return false
    }

    private func cleanup(activeDirectories: Set<URL>, stagingAge: TimeInterval?, includeCaches: Bool) -> AppCacheCleanupResult {
        var freed: Int64 = 0, removed = 0, failed = 0
        for url in stagingDirectories(activeDirectories: activeDirectories, olderThan: stagingAge) {
            let bytes = FileUsage.bytes(at: url)
            do {
                try FileManager.default.removeItem(at: url)
                freed += bytes
                removed += 1
            } catch {
                failed += 1
            }
        }
        if includeCaches {
            for url in cacheEntries() {
                let bytes = FileUsage.bytes(at: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    freed += bytes
                    removed += 1
                } catch {
                    failed += 1
                }
            }
        }
        return AppCacheCleanupResult(freedBytes: freed, removedItems: removed, failedItems: failed)
    }

    private func stagingDirectories(activeDirectories: Set<URL>, olderThan: TimeInterval?) -> [URL] {
        guard let entries = directoryEntries(at: temporaryRoot) else { return [] }
        let active = Set(activeDirectories.map(\.standardizedFileURL))
        let cutoff = olderThan.map { Date().addingTimeInterval(-$0) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        return entries.filter { url in
            guard Self.isStagingName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !active.contains(url.standardizedFileURL) else { return false }
            if let cutoff, let modified = values.contentModificationDate, modified >= cutoff { return false }
            return true
        }
    }

    private func cacheEntries() -> [URL] {
        directoryEntries(at: cachesRoot) ?? []
    }

    private func directoryEntries(at root: URL) -> [URL]? {
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys:
            [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
    }
}
