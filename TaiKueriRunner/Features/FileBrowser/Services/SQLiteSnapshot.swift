import Foundation
import Darwin

enum SQLiteSnapshot {
    static let maximumBytes = 64 * 1024 * 1024
    static let extensions: Set<String> = ["db", "db3", "sqlite", "sqlite3", "sqlitedb"]

    // Never open the source through SQLite: even a read-only WAL connection can
    // create/update shared memory. Only the private copy is passed to SQLite.
    static func copy(path: String, to destination: URL) throws {
        let paths = [path, path + "-wal", path + "-journal"]
        let before = try paths.map { try Stamp(path: $0) }
        guard let main = before[0], main.size >= 100 else { throw RunnerError(localized: "SQLiteデータベースではありません。") }
        guard before[2] == nil || before[2]?.size == 0 else {
            throw RunnerError(localized: "ジャーナルが残っています。元のアプリでDBを正常に閉じてから開いてください。")
        }
        guard main.size <= maximumBytes, (before[1]?.size ?? 0) <= maximumBytes - main.size else {
            throw RunnerError(localized: "SQLite表示はDBとWALの合計64 MiBまでです。")
        }
        try copyFile(path: path, to: destination, verifyHeader: true)
        if before[1] != nil {
            try copyFile(path: path + "-wal", to: URL(fileURLWithPath: destination.path + "-wal"))
        }
        guard try paths.map({ try Stamp(path: $0) }) == before else {
            throw RunnerError(localized: "コピー中にDBまたは関連ファイルが変更されました。元のアプリを停止してから読み直してください。")
        }
    }

    private static func copyFile(path: String, to destination: URL, verifyHeader: Bool = false) throws {
        try StableFileReader.withFile(path: path, maximumBytes: maximumBytes) { input, size in
            if verifyHeader {
                guard try input.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
                    throw RunnerError(localized: "SQLite形式ではないか、暗号化されたDBです。")
                }
                try input.seek(toOffset: 0)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RunnerError(localized: "SQLite表示用の一時コピーを作成できません。")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: min(1_048_576, size - copied)) ?? Data()
                guard !bytes.isEmpty else { throw RunnerError(localized: "SQLiteのコピー中にファイルが変更されました。") }
                try output.write(contentsOf: bytes)
                copied += bytes.count
            }
        }
    }

    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init?(path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= SQLiteSnapshot.maximumBytes else {
                throw RunnerError(localized: "SQLite表示には64 MiB以下の通常ファイルだけを使用できます。リンクには対応しません。")
            }
            device = info.st_dev; inode = info.st_ino; size = Int(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
}
