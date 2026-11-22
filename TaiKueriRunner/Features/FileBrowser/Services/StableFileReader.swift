import Foundation
import Darwin

enum StableFileReader {
    // Refuse links/special files and compare both the open descriptor and path
    // after decoding. A live, concurrently changing database is not a snapshot.
    static func withFile<T>(path: String, maximumBytes: Int, operation: (FileHandle, Int) throws -> T) throws -> T {
        guard maximumBytes >= 0, !path.contains("\0") else { throw RunnerError(localized: "無効なファイル指定です。") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw RunnerError(localized: "通常のファイルだけを読み取れます。") }
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else { throw RunnerError(localized: "ファイルが表示上限（\(String(describing: ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)))）を超えています。") }
        let result = try operation(FileHandle(fileDescriptor: fd, closeOnDealloc: false), Int(before.st_size))
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(path, &current) == 0,
              sameFile(before, after), sameFile(before, current) else {
            throw RunnerError(localized: "読み取り中にファイルが変更・置換されました。更新して読み直してください。")
        }
        return result
    }

    static func read<T>(path: String, maximumBytes: Int, decode: (Data) throws -> T) throws -> T {
        try withFile(path: path, maximumBytes: maximumBytes) { handle, size in
            var data = Data()
            data.reserveCapacity(size)
            while data.count <= maximumBytes {
                try Task.checkCancellation()
                let part = try handle.read(upToCount: min(1_048_576, maximumBytes - data.count + 1)) ?? Data()
                if part.isEmpty { break }
                data.append(part)
            }
            guard data.count == size, data.count <= maximumBytes else { throw RunnerError(localized: "読み取り中にファイルサイズが変更されました。") }
            return try decode(data)
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
