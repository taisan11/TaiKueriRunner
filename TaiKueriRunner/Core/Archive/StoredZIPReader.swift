import Foundation
import Darwin
import Compression

// Read-only counterpart of StoredZIPArchive: lists entries from the central
// directory and streams individual entries to disk. Method 0 (stored) is what
// this app writes; method 8 (raw DEFLATE) is accepted for archives made by
// other tools. Entries are never fully buffered in memory.
struct StoredZIPEntry: Identifiable, Sendable, Equatable {
    let name: String
    let method: UInt16
    let compressedBytes: Int
    let uncompressedBytes: Int
    let crc32: UInt32
    // Payload offset, already past the local header, name and extra fields.
    let dataOffset: Int
    let flags: UInt16
    var id: String { name }
    var encrypted: Bool { flags & 0x0001 != 0 }
    var directory: Bool { name.hasSuffix("/") }
}

enum StoredZIPReader {
    static let maximumEntries = 100_000
    static let maximumNameBytes = 4096
    static let maximumArchiveBytes = 8 * 1024 * 1024 * 1024
    static let chunkBytes = 1_048_576

    struct Archive {
        let path: String
        let entries: [StoredZIPEntry]
        private let handle: FileHandle

        fileprivate init(path: String, entries: [StoredZIPEntry], handle: FileHandle) {
            self.path = path
            self.entries = entries
            self.handle = handle
        }

        func entry(named name: String) -> StoredZIPEntry? {
            entries.first { $0.name == name }
        }

        // The destination is a caller-chosen staging path, never derived from
        // the entry name, so archive paths cannot escape the staging folder.
        func extract(_ entry: StoredZIPEntry, to destination: URL) throws {
            try Task.checkCancellation()
            guard !entry.encrypted else { throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」は暗号化されています。") }
            guard !entry.directory else { throw RunnerError(localized: "ZIP内のフォルダエントリは展開できません。") }
            guard entry.uncompressedBytes >= 0, entry.uncompressedBytes <= ApplicationDataExport.maximumArchiveBytes else {
                throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」が展開上限を超えています。")
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RunnerError(localized: "展開先の一時ファイルを作成できません。")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var crc = UInt32.max
            let written = try stream(entry) { chunk in
                crc = StoredZIPReader.update(crc, with: chunk)
                try output.write(contentsOf: chunk)
            }
            guard written == entry.uncompressedBytes, crc ^ UInt32.max == entry.crc32 else {
                throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」がCRCまたはサイズ不一致のため展開できません。")
            }
        }

        // In-memory variant used by the media viewer. The entry is streamed
        // through the same CRC and size validation as extract(), without
        // writing a per-image temporary file.
        func read(_ entry: StoredZIPEntry, maximumBytes: Int) throws -> Data {
            guard !entry.encrypted else { throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」は暗号化されています。") }
            guard !entry.directory else { throw RunnerError(localized: "ZIP内のフォルダエントリは読み取れません。") }
            guard entry.uncompressedBytes >= 0, entry.uncompressedBytes <= maximumBytes else {
                throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」が表示上限を超えています。")
            }
            var data = Data()
            data.reserveCapacity(entry.uncompressedBytes)
            var crc = UInt32.max
            let written = try stream(entry) { chunk in
                crc = StoredZIPReader.update(crc, with: chunk)
                data.append(chunk)
            }
            guard written == entry.uncompressedBytes, crc ^ UInt32.max == entry.crc32 else {
                throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」がCRCまたはサイズ不一致のため読み取れません。")
            }
            return data
        }

        // Streams a stored or DEFLATE entry into consume(). The caller is
        // responsible for CRC accounting so extraction and in-memory reads use
        // exactly the same decoded bytes and bounds checks.
        private func stream(_ entry: StoredZIPEntry, consume: (Data) throws -> Void) throws -> Int {
            handle.seek(toFileOffset: UInt64(entry.dataOffset))
            var written = 0
            switch entry.method {
            case 0:
                while written < entry.compressedBytes {
                    try Task.checkCancellation()
                    let bytes = try handle.read(upToCount: min(StoredZIPReader.chunkBytes, entry.compressedBytes - written)) ?? Data()
                    guard !bytes.isEmpty else { throw RunnerError(localized: "ZIPの読み取り中にデータが途切れました。") }
                    try consume(bytes)
                    written += bytes.count
                    guard written <= entry.uncompressedBytes else { throw RunnerError(localized: "ZIPのデータサイズが中央ディレクトリの記録と一致しません。") }
                }
            case 8:
                written = try inflate(entry: entry, input: handle, consume: consume)
            default:
                throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」は対応していない圧縮方式（method \(String(describing: entry.method))）です。")
            }
            return written
        }

        // Raw DEFLATE (RFC 1951). Apple's COMPRESSION_ZLIB is headerless and
        // matches the ZIP method-8 payload directly.
        private func inflate(entry: StoredZIPEntry, input: FileHandle, consume: (Data) throws -> Void) throws -> Int {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: StoredZIPReader.chunkBytes)
            defer { destination.deallocate() }
            let source = UnsafeMutablePointer<UInt8>.allocate(capacity: StoredZIPReader.chunkBytes)
            defer { source.deallocate() }
            var stream = compression_stream(dst_ptr: destination, dst_size: StoredZIPReader.chunkBytes,
                                             src_ptr: UnsafePointer(source), src_size: 0,
                                             state: nil)
            var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            guard status == COMPRESSION_STATUS_OK else { throw RunnerError(localized: "DEFLATE展開を初期化できません。") }
            defer { compression_stream_destroy(&stream) }
            // compression_stream_init clears the buffer fields: re-describe
            // the destination and source before the first process call.
            stream.dst_ptr = destination
            stream.dst_size = StoredZIPReader.chunkBytes
            stream.src_ptr = UnsafePointer(source)
            stream.src_size = 0
            var read = 0, written = 0, finished = false
            func emit() throws {
                let produced = StoredZIPReader.chunkBytes - stream.dst_size
                if produced > 0 {
                    try consume(Data(bytes: destination, count: produced))
                    written += produced
                    guard written <= entry.uncompressedBytes else { throw RunnerError(localized: "ZIPの展開結果がサイズ上限を超えています。") }
                }
                stream.dst_ptr = destination
                stream.dst_size = StoredZIPReader.chunkBytes
            }
            while !finished {
                try Task.checkCancellation()
                if stream.src_size == 0 {
                    if read < entry.compressedBytes {
                        let chunk = try input.read(upToCount: min(StoredZIPReader.chunkBytes, entry.compressedBytes - read)) ?? Data()
                        guard !chunk.isEmpty else { throw RunnerError(localized: "ZIPの読み取り中にデータが途切れました。") }
                        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                            source.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: chunk.count)
                        }
                        stream.src_ptr = UnsafePointer(source)
                        stream.src_size = chunk.count
                        read += chunk.count
                    } else {
                        // Truncated stream: fail instead of guessing padding.
                        throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」の圧縮データが不完全です。")
                    }
                }
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                try emit()
                if status == COMPRESSION_STATUS_END {
                    finished = true
                } else if status == COMPRESSION_STATUS_ERROR {
                    throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」を展開できません。")
                }
            }
            guard read == entry.compressedBytes else { throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」の圧縮データが不完全です。") }
            return written
        }
    }

    // Mirrors StableFileReader: open once, validate a regular file, detect
    // concurrent changes, and close even on thrown errors.
    static func withArchive<T>(path: String, maximumBytes: Int = maximumArchiveBytes, operation: (Archive) throws -> T) throws -> T {
        guard maximumBytes >= 0, !path.contains("\0") else { throw RunnerError(localized: "無効なファイル指定です。") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw RunnerError(localized: "通常のファイルだけを読み取れます。") }
        guard before.st_size >= 22, before.st_size <= Int64(maximumBytes) else {
            throw RunnerError(localized: "ZIPが読み取り上限（\(String(describing: ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)))）を超えているか、大きさが足りません。")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let entries = try parseCentralDirectory(handle, fileSize: Int(before.st_size))
        let result = try operation(Archive(path: path, entries: entries, handle: handle))
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(path, &current) == 0,
              sameIdentity(before, after), sameIdentity(before, current) else {
            throw RunnerError(localized: "読み取り中にZIPが変更・置換されました。")
        }
        return result
    }

    // Reads one indexed entry without re-parsing the central directory. The
    // media index stores StoredZIPEntry values captured during the initial
    // scan; offsets are revalidated against the current file identity so a
    // changed or replaced archive fails instead of returning wrong bytes.
    static func readEntry(path: String, entry: StoredZIPEntry, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, !path.contains("\0") else { throw RunnerError(localized: "無効なファイル指定です。") }
        guard entry.uncompressedBytes >= 0, entry.uncompressedBytes <= maximumBytes else {
            throw RunnerError(localized: "ZIP内の「\(String(describing: entry.name))」が表示上限を超えています。")
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw RunnerError(localized: "通常のファイルだけを読み取れます。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let archive = Archive(path: path, entries: [entry], handle: handle)
        let data = try archive.read(entry, maximumBytes: maximumBytes)
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, lstat(path, &current) == 0,
              sameIdentity(before, after), sameIdentity(before, current) else {
            throw RunnerError(localized: "読み取り中にZIPが変更・置換されました。")
        }
        return data
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func parseCentralDirectory(_ handle: FileHandle, fileSize: Int) throws -> [StoredZIPEntry] {
        // Locate the end-of-central-directory record, which may be preceded by
        // an arbitrary (here: empty) file comment. Scan the last 64 KiB + 22.
        let scanWindow = min(UInt64(fileSize), UInt64(66_558))
        handle.seek(toFileOffset: UInt64(fileSize) - scanWindow)
        let tail = try handle.read(upToCount: Int(scanWindow)) ?? Data()
        guard tail.count == Int(scanWindow) else { throw RunnerError(localized: "ZIPの終端レコードを読み取れません。") }
        var end: (count: Int, size: Int, offset: Int)?
        for index in tail.indices.reversed() where index + 22 <= tail.count && tail[index ..< index + 4] == Data([0x50, 0x4b, 0x05, 0x06]) {
            let values = tail[index...]
            let count = Int(values.zip16(8)), size = Int(values.zip32(12)), offset = Int(values.zip32(16))
            guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF, offset + size <= fileSize else { continue }
            end = (count, size, offset)
            break
        }
        guard let end else { throw RunnerError(localized: "ZIP形式（ZIP64を除く）ではありません。") }
        guard end.count <= maximumEntries else { throw RunnerError(localized: "ZIPの項目数が上限を超えています。") }
        handle.seek(toFileOffset: UInt64(end.offset))
        var data = Data()
        while data.count < end.size {
            try Task.checkCancellation()
            let part = try handle.read(upToCount: min(1_048_576, end.size - data.count)) ?? Data()
            guard !part.isEmpty else { throw RunnerError(localized: "ZIPの中央ディレクトリを読み取れません。") }
            data.append(part)
        }
        guard data.count == end.size else { throw RunnerError(localized: "ZIPの中央ディレクトリが不完全です。") }
        var entries: [StoredZIPEntry] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard cursor + 46 <= data.endIndex, data[cursor ..< cursor + 4] == Data([0x50, 0x4b, 0x01, 0x02]) else {
                throw RunnerError(localized: "ZIPの中央ディレクトリが壊れています。")
            }
            let record = data[cursor...]
            let flags = record.zip16(8), method = record.zip16(10)
            let crc = record.zip32(16)
            let compressed = record.zip32(20), uncompressed = record.zip32(24)
            let nameLength = Int(record.zip16(28)), extraLength = Int(record.zip16(30)), commentLength = Int(record.zip16(32))
            let localOffset = Int(record.zip32(42))
            guard cursor + 46 + nameLength <= data.endIndex, nameLength <= maximumNameBytes else {
                throw RunnerError(localized: "ZIPのファイル名が長すぎるか、データが壊れています。")
            }
            // ZIP64 markers (0xFFFFFFFF) are rejected entry by entry.
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { continue }
            let nameData = data[cursor + 46 ..< cursor + 46 + nameLength]
            guard !nameData.contains(0) else { throw RunnerError(localized: "ZIPのファイル名が不正です。") }
            let name = String(decoding: nameData, as: UTF8.self)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.components(separatedBy: "/").contains("..") else {
                throw RunnerError(localized: "ZIPに安全でないパス「\(String(describing: name))」が含まれています。")
            }
            let local = try localHeader(handle, offset: localOffset, name: nameData)
            entries.append(StoredZIPEntry(name: name, method: method, compressedBytes: Int(compressed),
                                          uncompressedBytes: Int(uncompressed), crc32: crc, dataOffset: local,
                                          flags: flags))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard entries.count == end.count else { throw RunnerError(localized: "ZIPの中央ディレクトリが項目数と一致しません。") }
        return entries
    }

    // Returns the payload offset behind the local header. Sizes in the local
    // header may be zero (data descriptor), so only its name is validated.
    private static func localHeader(_ handle: FileHandle, offset: Int, name: Data) throws -> Int {
        handle.seek(toFileOffset: UInt64(offset))
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header[0 ..< 4] == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw RunnerError(localized: "ZIPのローカルヘッダーが壊れています。")
        }
        let nameLength = Int(header.zip16(26)), extraLength = Int(header.zip16(28))
        return offset + 30 + nameLength + extraLength
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var value = crc
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xff)] ^ (value >> 8)
        }
        return value
    }

    private static let table: [UInt32] = {
        (0..<256).map { index in
            var crc = UInt32(index)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            return crc
        }
    }()
}

private extension Data {
    func zip16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func zip32(_ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            value |= UInt32(self[startIndex + offset + shift / 8]) << UInt32(shift)
        }
        return value
    }
}
