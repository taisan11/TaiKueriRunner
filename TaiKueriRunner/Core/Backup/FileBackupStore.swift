import Foundation
import Darwin
import CryptoKit

// Persistent, per-operation backups, never a cache. No automatic pruning.
// A failed or incomplete backup must never authorize a mutation.
struct FileBackupStore {
    static let maximumBytes: Int64 = 256 * 1024 * 1024
    static let maximumItems = 10_000
    let root: URL

    struct Snapshot: Equatable, Codable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        var isRegular: Bool { mode & S_IFMT == S_IFREG }
    }

    struct Backup {
        let directory: URL
        let payload: URL
        let snapshot: [String: Snapshot]
    }

    func protect(_ url: URL) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let backup = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != "/", path != backup, !path.hasPrefix(backup + "/"), !backup.hasPrefix(path + "/") else {
            throw RunnerError(localized: "ルート、バックアップ領域、またはその上位フォルダは変更対象にできません。")
        }
    }

    func snapshot(_ source: URL) throws -> [String: Snapshot] {
        var result: [String: Snapshot] = [:]
        var bytes: Int64 = 0
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            let item = try Snapshot(path: url.path)
            guard item.isRegular || item.isDirectory else {
                throw RunnerError(localized: "安全なバックアップのため、シンボリックリンク・特殊ファイルを含む操作は実行しません。")
            }
            bytes += item.isRegular ? item.size : 0
            guard depth <= 64, result.count < Self.maximumItems, bytes <= Self.maximumBytes else {
                throw RunnerError(localized: "バックアップ上限（256 MiB・10,000項目・深さ64）を超えています。操作は実行しません。")
            }
            result[relative] = item
            if item.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
        }
        try visit(source, relative: ".", depth: 0)
        return result
    }

    func prepare(operation: FileWriteOperation, source: URL?, destination: URL?, wallpaper: WallpaperBackupMetadata? = nil) throws -> Backup {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let payload = directory.appendingPathComponent("original")
        do {
            let before = try source.map(snapshot) ?? [:]
            var hashes: [String: String] = [:]
            if let source {
                try files.copyItem(at: source, to: payload)
                guard try snapshot(source) == before else {
                    throw RunnerError(localized: "バックアップ中に元データが変更されました。操作を中止しました。")
                }
                // Verify bytes against each stable source, not just the copy's size.
                for (relative, entry) in before where entry.isRegular {
                    let copy = relative == "." ? payload : payload.appendingPathComponent(String(relative.dropFirst(2)))
                    let original = relative == "." ? source : source.appendingPathComponent(String(relative.dropFirst(2)))
                    try StableFileReader.withFile(path: original.path, maximumBytes: Int(Self.maximumBytes)) { input, originalSize in
                        try StableFileReader.withFile(path: copy.path, maximumBytes: Int(Self.maximumBytes)) { output, copySize in
                            guard Int64(copySize) == entry.size, originalSize == copySize else { throw RunnerError(localized: "バックアップのサイズが一致しません。") }
                            var hasher = SHA256()
                            while true {
                                try Task.checkCancellation()
                                let bytes = try input.read(upToCount: 1_048_576) ?? Data()
                                guard (try output.read(upToCount: 1_048_576) ?? Data()) == bytes else { throw RunnerError(localized: "バックアップの内容が一致しません。") }
                                if bytes.isEmpty { break }
                                hasher.update(data: bytes)
                            }
                            hashes[relative] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                            try output.synchronize()
                        }
                    }
                }
                guard try snapshot(source) == before else { throw RunnerError(localized: "バックアップ検証中に元データが変更されました。") }
            }
            let manifest = FileBackupManifest(version: 2, created: Date(), operation: operation.title, kind: operation.kind, sourcePath: source?.path,
                                    destinationPath: destination?.path,
                                    destinationWasAbsent: destination != nil && destination != source,
                                     parent: try (destination != source ? destination : nil).map { try Snapshot(path: $0.deletingLastPathComponent().path) }, entries: before, hashes: hashes,
                                     wallpaper: wallpaper)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: manifestURL)
            defer { try? handle.close() }
            try handle.synchronize()
            return Backup(directory: directory, payload: payload, snapshot: before)
        } catch {
            // Only remove this store's newly created, incomplete backup directory.
            try? files.removeItem(at: directory)
            throw error
        }
    }

    func record(id: String) throws -> FileBackupRecord {
        guard let uuid = UUID(uuidString: id) else { throw RunnerError(localized: "無効なバックアップIDです。") }
        let directory = root.appendingPathComponent(uuid.uuidString, isDirectory: true)
        guard try Snapshot(path: directory.path).isDirectory else { throw RunnerError(localized: "バックアップ領域が不正です。") }
        let decoder = JSONDecoder()
        let manifest = try StableFileReader.read(path: directory.appendingPathComponent("manifest.json").path, maximumBytes: 8 * 1024 * 1024) {
            try decoder.decode(FileBackupManifest.self, from: $0)
        }
        guard (1...2).contains(manifest.version), manifest.entries.count <= Self.maximumItems else { throw RunnerError(localized: "バックアップ形式が不正です。") }
        for relative in manifest.entries.keys {
            guard relative == "." || (relative.hasPrefix("./") && relative.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw RunnerError(localized: "バックアップの相対パスが不正です。")
            }
        }
        let outcomeURL = directory.appendingPathComponent("outcome.json")
        let outcome: FileBackupOutcome?
        if FileManager.default.fileExists(atPath: outcomeURL.path) {
            outcome = try StableFileReader.read(path: outcomeURL.path, maximumBytes: 8 * 1024 * 1024) { try decoder.decode(FileBackupOutcome.self, from: $0) }
        } else { outcome = nil }
        return FileBackupRecord(id: uuid.uuidString, directory: directory, manifest: manifest, outcome: outcome)
    }

    func list() throws -> FileBackupListing {
        var info = stat()
        if lstat(root.path, &info) != 0, errno == ENOENT { return FileBackupListing(records: [], unreadableCount: 0) }
        var records: [FileBackupRecord] = [], invalid = 0
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            do { records.append(try record(id: url.lastPathComponent)) }
            catch is CancellationError { throw CancellationError() }
            catch { invalid += 1 }
        }
        return FileBackupListing(records: records.sorted { $0.manifest.created > $1.manifest.created }, unreadableCount: invalid)
    }

    // Deletes only a direct UUID directory under this store's root. The target
    // files described by the manifest are never touched.
    func delete(id: String) throws -> Int64 {
        guard let uuid = UUID(uuidString: id) else { throw RunnerError(localized: "無効なバックアップIDです。") }
        let rootSnapshot = try Snapshot(path: root.path)
        guard rootSnapshot.isDirectory else { throw RunnerError(localized: "バックアップ領域が不正です。") }
        let directory = root.appendingPathComponent(uuid.uuidString, isDirectory: true)
        let snapshot = try Snapshot(path: directory.path)
        guard snapshot.isDirectory else { throw RunnerError(localized: "バックアップ領域が不正です。") }
        let bytes = FileUsage.bytes(at: directory)
        try FileManager.default.removeItem(at: directory)
        return bytes
    }

    func verifyPayload(_ record: FileBackupRecord) throws {
        let actual = try snapshot(record.payload)
        guard Set(actual.keys) == Set(record.manifest.entries.keys) else { throw RunnerError(localized: "バックアップの構成が記録と一致しません。") }
        for (relative, original) in record.manifest.entries {
            guard let copy = actual[relative], copy.isDirectory == original.isDirectory,
                  !copy.isRegular || copy.size == original.size else { throw RunnerError(localized: "バックアップの型・サイズが記録と一致しません。") }
            if copy.isRegular, let expected = record.manifest.hashes?[relative] {
                let url = relative == "." ? record.payload : record.payload.appendingPathComponent(String(relative.dropFirst(2)))
                let hash = try StableFileReader.withFile(path: url.path, maximumBytes: Int(Self.maximumBytes)) { handle, _ in
                    var hasher = SHA256()
                    while true {
                        try Task.checkCancellation()
                        let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
                        if bytes.isEmpty { break }
                        hasher.update(data: bytes)
                    }
                    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
                guard hash == expected else { throw RunnerError(localized: "バックアップの整合性検証に失敗しました。復元しません。") }
            } else if copy.isRegular, record.manifest.version >= 2 { throw RunnerError(localized: "バックアップのハッシュがありません。") }
        }
    }

    func finish(_ backup: Backup, changedPath: String?, succeeded: Bool) throws {
        let state: [String: Snapshot]?
        if succeeded, let changedPath, FileManager.default.fileExists(atPath: changedPath) { state = try snapshot(URL(fileURLWithPath: changedPath)) }
        else { state = nil }
        let outcome = FileBackupOutcome(succeeded: succeeded, changedPath: changedPath, snapshot: state)
        let url = backup.directory.appendingPathComponent("outcome.json")
        try JSONEncoder().encode(outcome).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
