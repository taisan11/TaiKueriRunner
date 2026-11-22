import Foundation
import Darwin

// Read-only, bounded data export. ZIP creation sees only our private copy.
enum ApplicationDataExport {
    typealias ReadAccess = (_ path: String, _ directory: Bool, _ operation: () throws -> Void) throws -> Void

    struct SourceReadFailure: LocalizedError {
        let path: String
        let operation: String
        let underlying: Error
        var errorDescription: String? {
            let error = underlying as NSError
            return L("元データを読み取れません。\n操作: \(String(describing: operation))\n対象: \(String(describing: path))\n\(String(describing: error.localizedDescription))\n\(String(describing: error.domain)) (\(String(describing: error.code)))")
        }
    }

    struct Failure: LocalizedError {
        let phase: String
        let underlying: Error
        var errorDescription: String? {
            if let source = underlying as? SourceReadFailure { return L("\(String(describing: phase))に失敗しました。\n\(String(describing: source.localizedDescription))") }
            let error = underlying as NSError
            return L("\(String(describing: phase))に失敗しました。\n\(String(describing: error.localizedDescription))\n\(String(describing: error.domain)) (\(String(describing: error.code)))")
        }
    }

    struct Limits: Sendable {
        var maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
        var maximumItems = 50_000
        var maximumDepth = 128
    }

    struct SkippedItem: Codable, Sendable {
        let path: String
        let operation: String
        let reason: String
        let errorDomain: String
        let errorCode: Int
    }

    struct Report: Codable, Sendable {
        let copiedFileCount: Int
        let copiedBytes: Int64
        let skippedItems: [SkippedItem]
        var isPartial: Bool { !skippedItems.isEmpty }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            guard data.count <= 64 * 1024 * 1024 else { throw RunnerError(localized: "省略レポートのサイズが上限を超えています。") }
            return data
        }
    }

    struct StagedExport: Sendable {
        let document: StagedDocumentPreview
        let report: Report
    }

    static let maximumArchiveBytes = 3 * 1024 * 1024 * 1024

    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modified: timespec
        let changed: timespec

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modified = info.st_mtimespec; changed = info.st_ctimespec
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size && lhs.mode == rhs.mode &&
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    // Shared by app container and App Group exports. Only a flat, sanitized
    // identifier is used so a source path can never escape the staging folder.
    static func archiveFilename(identifier: String, fallback: String = "Export") -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let name = String(identifier.prefix(120).map { allowed.contains($0) ? $0 : "_" })
        return (name.isEmpty ? fallback : name) + "-data.zip"
    }

    static func archiveFilename(bundleID: String) -> String {
        archiveFilename(identifier: bundleID, fallback: "Application")
    }

    @discardableResult
    static func copy(source: URL, to destination: URL, limits: Limits = Limits(), skipUnreadable: Bool = true,
                     readAccess: ReadAccess = { _, _, operation in try operation() }) throws -> Report {
        guard limits.maximumBytes > 0, limits.maximumBytes <= Limits().maximumBytes,
              (1...Limits().maximumItems).contains(limits.maximumItems), (0...Limits().maximumDepth).contains(limits.maximumDepth) else {
            throw RunnerError(localized: "エクスポート上限が不正です。")
        }
        let sourcePath = try FileRules.canonical(source.path)
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
        // The running app's workspace may live in its own tmp, which is excluded.
        guard resolvedSource != "/", target != resolvedSource,
              !target.hasPrefix(resolvedSource + "/") || target.hasPrefix(resolvedSource + "/tmp/") else {
            throw RunnerError(localized: "エクスポート先を元データの中には作成できません。")
        }
        // Only source reads are retried. A failure writing our private copy must
        // never cause an access request for the source or an unrelated directory.
        func readSource<T>(_ path: String, directory: Bool, action: String = L("属性の確認"), _ operation: () throws -> T) throws -> T {
            do {
                var result: T?
                try withoutActuallyEscaping(operation) { operation in
                    try readAccess(path, directory) { result = .some(try operation()) }
                }
                guard let result else { throw RunnerError(localized: "読み取り処理が実行されませんでした。") }
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { throw SourceReadFailure(path: path, operation: action, underlying: error) }
        }
        let fd = try readSource(sourcePath, directory: true, action: L("コンテナを開く")) {
            let descriptor = open(sourcePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixError() }
            return descriptor
        }
        defer { close(fd) }

        var skipped: [SkippedItem] = []
        func collect(to copyRoot: URL?, excluding omitted: Set<String> = []) throws -> [String: Stamp] {
            var entries: [String: Stamp] = [:]
            var recordedKeys: [String] = []
            var bytes: Int64 = 0
            var visitedItems = 1
            func visit(_ descriptor: Int32, relative: String, depth: Int, copy: URL?) throws {
                try Task.checkCancellation()
                let path = relative == "." ? sourcePath : source.appendingPathComponent(String(relative.dropFirst(2))).path
                var info = stat()
                try readSource(path, directory: relative == ".") {
                    guard fstat(descriptor, &info) == 0 else { throw posixError() }
                }
                let before = Stamp(info)
                let directory = info.st_mode & S_IFMT == S_IFDIR
                guard directory || info.st_mode & S_IFMT == S_IFREG else {
                    throw RunnerError(localized: "リンク・特殊ファイルを含むデータはエクスポートできません。")
                }
                guard depth <= limits.maximumDepth,
                      directory || (info.st_size >= 0 && info.st_size <= limits.maximumBytes - bytes) else {
                    throw RunnerError(localized: "エクスポート上限（2 GiB・50,000項目・深さ128）を超えています。")
                }
                entries[relative] = before
                recordedKeys.append(relative)
                if directory {
                    if let copy {
                        guard mkdir(copy.path, 0o700) == 0 else { throw posixError() }
                    }
                    let nameLimit = limits.maximumItems + (relative == "." ? 2 : 0)
                    for name in try readSource(path, directory: true, action: L("フォルダ一覧"), { try names(in: descriptor, maximumItems: nameLimit) }) {
                        // Container-manager metadata belongs to iOS, not the app.
                        // It can be protected even when the folder is listable.
                        if relative == "." && (name == "tmp" || name == ".com.apple.mobile_container_manager.metadata.plist") { continue }
                        visitedItems += 1
                        guard visitedItems <= limits.maximumItems else { throw RunnerError(localized: "エクスポートの項目数が上限を超えています。") }
                        let childRelative = relative + "/" + name
                        if omitted.contains(childRelative) { continue }
                        let childPath = URL(fileURLWithPath: path).appendingPathComponent(name).path
                        let childCopy = copy?.appendingPathComponent(name)
                        let previousBytes = bytes, previousSkipped = skipped.count, previousKeys = recordedKeys.count
                        do {
                            var childInfo = stat()
                            try readSource(childPath, directory: false) {
                                guard fstatat(descriptor, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                            }
                            let kind = childInfo.st_mode & S_IFMT
                            guard kind == S_IFREG || kind == S_IFDIR else {
                                throw RunnerError(localized: "リンク・特殊ファイルを含むデータはエクスポートできません。")
                            }
                            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0)
                            let child = try readSource(childPath, directory: kind == S_IFDIR, action: L("子フォルダ・ファイルを開く")) {
                                let descriptor = openat(descriptor, name, flags)
                                guard descriptor >= 0 else { throw posixError() }
                                return descriptor
                            }
                            defer { close(child) }
                            var opened = stat()
                            try readSource(childPath, directory: kind == S_IFDIR) {
                                guard fstat(child, &opened) == 0 else { throw posixError() }
                            }
                            guard Stamp(opened) == Stamp(childInfo) else { throw changedError() }
                            try visit(child, relative: childRelative, depth: depth + 1, copy: childCopy)
                            var current = stat()
                            try readSource(childPath, directory: kind == S_IFDIR) {
                                guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
                            }
                            guard Stamp(current) == Stamp(childInfo) else { throw changedError() }
                        } catch let failure as SourceReadFailure where copyRoot != nil && skipUnreadable && isPermissionDenial(failure.underlying) {
                            // Never keep a truncated file or a partially copied subtree.
                            if let childCopy, FileManager.default.fileExists(atPath: childCopy.path) {
                                try FileManager.default.removeItem(at: childCopy)
                            }
                            for key in recordedKeys[previousKeys...] { entries.removeValue(forKey: key) }
                            recordedKeys.removeSubrange(previousKeys...)
                            bytes = previousBytes
                            skipped.removeSubrange(previousSkipped...)
                            let error = failure.underlying as NSError
                            skipped.append(SkippedItem(path: String(childRelative.dropFirst(2)), operation: failure.operation,
                                                       reason: error.localizedDescription, errorDomain: error.domain, errorCode: error.code))
                        }
                    }
                } else {
                    bytes += info.st_size
                    if let copy {
                        try copyFile(descriptor: descriptor, size: Int(info.st_size), to: copy) { input, count in
                            try readSource(path, directory: false, action: L("ファイル内容の読み取り")) { try input.read(upToCount: count) ?? Data() }
                        }
                    }
                }
                var after = stat()
                try readSource(path, directory: directory) {
                    guard fstat(descriptor, &after) == 0 else { throw posixError() }
                }
                guard Stamp(after) == before else { throw changedError() }
            }
            try visit(fd, relative: ".", depth: 0, copy: copyRoot)
            return entries
        }

        let copied = try collect(to: destination)
        let omitted = Set(skipped.map { "./" + $0.path })
        guard try collect(to: nil, excluding: omitted) == copied else { throw changedError() }
        var current = stat()
        try readSource(sourcePath, directory: true) {
            guard lstat(sourcePath, &current) == 0 else { throw posixError() }
        }
        guard Stamp(current) == copied["."] else { throw changedError() }
        let regularFiles = copied.values.filter { $0.mode & S_IFMT == S_IFREG }
        return Report(copiedFileCount: regularFiles.count, copiedBytes: regularFiles.reduce(0) { $0 + $1.size }, skippedItems: skipped)
    }

    static func archive(directory: URL, to destination: URL, report: Data? = nil) throws {
        try StoredZIPArchive.write(directory: directory, to: destination, maximumBytes: maximumArchiveBytes, report: report)
    }

    private static func isPermissionDenial(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)) ||
            (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue)
    }

    private static func names(in descriptor: Int32, maximumItems: Int) throws -> [String] {
        // dup shares a directory offset: rewind before every verification pass.
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw posixError() }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw posixError() }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard !name.isEmpty, !name.contains("/"), result.count < maximumItems else {
                throw RunnerError(localized: "エクスポートの項目数またはファイル名が上限を超えています。")
            }
            result.append(name)
        }
        return result.sorted()
    }

    private static func copyFile(descriptor: Int32, size: Int, to destination: URL,
                                 read: (FileHandle, Int) throws -> Data = { try $0.read(upToCount: $1) ?? Data() }) throws {
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw posixError() }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var copied = 0
        while copied < size {
            try Task.checkCancellation()
            let data = try read(input, min(1_048_576, size - copied))
            guard !data.isEmpty else { throw changedError() }
            try output.write(contentsOf: data)
            copied += data.count
        }
        guard try read(input, 1).isEmpty else { throw changedError() }
        try output.synchronize()
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func changedError() -> RunnerError {
        RunnerError(localized: "エクスポート中に元データが変更・置換されました。対象アプリを終了してから再実行してください。")
    }
}
