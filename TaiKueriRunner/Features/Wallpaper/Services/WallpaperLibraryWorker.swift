import Foundation

protocol WallpaperLibraryAccess: Actor {
    func readWallpaperDirectory(path: String, container: String) async throws -> [FileEntry]
    func readWallpaperAttributes(path: String, container: String) async throws -> FileBackupStore.Snapshot
    func readWallpaperMetadata(path: String, container: String, maximumBytes: Int) async throws -> Data
    func wallpaperBackupIDs() async throws -> [String]
    func wallpaperBackupRecord(id: String) async throws -> FileBackupRecord
}

// Traversal and presentation metadata never execute on the UI actor or hold the
// file-access actor for an entire scan. Each awaited I/O call owns its own session.
actor WallpaperLibraryWorker {
    private let files: any WallpaperLibraryAccess

    init(files: any WallpaperLibraryAccess) { self.files = files }

    func load(container: String, onProgress: @Sendable (WallpaperLibrarySnapshot) async -> Void) async throws -> WallpaperLibrarySnapshot {
        let root = try WallpaperPaths.container(container)
        var backups: [FileBackupRecord] = []
        for id in try await files.wallpaperBackupIDs() {
            try Task.checkCancellation()
            do { backups.append(try await files.wallpaperBackupRecord(id: id)) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Match the existing backup listing: malformed records cannot establish ownership. */ }
        }
        let reader = WallpaperLibraryReader(list: { [files] path in
            try await files.readWallpaperDirectory(path: path, container: root)
        }, read: { [files] path, maximum in
            try await files.readWallpaperMetadata(path: path, container: root, maximumBytes: maximum)
        }, inspect: { [files] path in
            try await files.readWallpaperAttributes(path: path, container: root)
        })
        return try await reader.load(container: root, backups: backups, onProgress: onProgress)
    }
}

// ImageIO decoding is also separate from sandbox queries and file mutations.
actor WallpaperImageWorker {
    static let shared = WallpaperImageWorker()

    func thumbnail(_ data: Data) throws -> Data? {
        try Task.checkCancellation()
        return try WallpaperThumbnail.make(data)
    }
}
