import Foundation
import zlib

// Read only the directory and selected entries, never the whole exported container.
// No subprocesses, ZIP64, encryption, links or implicit path normalization.
struct WallpaperZIP {
    static let maximumArchiveBytes = 1024 * 1024 * 1024
    static let maximumFileBytes = 64 * 1024 * 1024
    struct Entry: Equatable, Sendable {
        let name: String
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressed: Int
        let size: Int
        let offset: Int
        var directory: Bool { name.hasSuffix("/") }
    }
    let handle: FileHandle
    let entries: [Entry]
    let directoryOffset: Int

    init(handle: FileHandle, size: Int) throws {
        self.handle = handle
        guard size >= 22 else { throw RunnerError(localized: "ZIPではありません。") }
        let tailOffset = max(0, size - 65_557)
        let tail = try Self.read(handle, offset: tailOffset, count: size - tailOffset)
        guard let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail.u32($0) == 0x06054b50 && $0 + 22 + tail.u16($0 + 20) == tail.count
        }) else { throw RunnerError(localized: "ZIPの終端が不正です。") }
        let count = tail.u16(end + 10)
        let length = Int(tail.u32(end + 12)), offset = Int(tail.u32(end + 16))
        guard tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              count == tail.u16(end + 8), count < 65_535, count <= 50_000,
              length <= 16 * 1024 * 1024, offset + length == tailOffset + end else {
            throw RunnerError(localized: "分割ZIP・ZIP64・上限を超えるZIPには対応していません。")
        }
        let data = try Self.read(handle, offset: offset, count: length)
        var cursor = 0, result: [Entry] = [], names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor + 46 <= data.count, data.u32(cursor) == 0x02014b50 else { throw RunnerError(localized: "ZIPの目録が不正です。") }
            let nameLength = data.u16(cursor + 28)
            let next = cursor + 46 + nameLength + data.u16(cursor + 30) + data.u16(cursor + 32)
            guard next <= data.count, data.u16(cursor + 34) == 0,
                  let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else {
                throw RunnerError(localized: "ZIPの名前・範囲が不正です（UTF-8のみ対応）。")
            }
            let components = (name.hasSuffix("/") ? String(name.dropLast()) : name).split(separator: "/", omittingEmptySubsequences: false)
            let mode = (data.u32(cursor + 38) >> 16) & 0xf000
            guard !components.isEmpty, components.count <= 64, name.utf8.count <= 4096,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") }),
                  name.rangeOfCharacter(from: .controlCharacters) == nil,
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  mode == 0 || mode == 0x8000 || mode == 0x4000 else {
                throw RunnerError(localized: "ZIPに危険なパス・重複・リンク・特殊ファイルがあります。")
            }
            let entry = Entry(name: name, flags: data.u16(cursor + 8), method: data.u16(cursor + 10),
                              crc: data.u32(cursor + 16), compressed: Int(data.u32(cursor + 20)),
                              size: Int(data.u32(cursor + 24)), offset: Int(data.u32(cursor + 42)))
            guard entry.flags & ~0x080e == 0, entry.flags & 1 == 0,
                  entry.method == 0 || entry.method == 8,
                  entry.offset + 30 + entry.compressed <= offset else {
                throw RunnerError(localized: "暗号化・非対応の圧縮方式、または不正なZIP範囲です。")
            }
            result.append(entry)
            cursor = next
        }
        guard cursor == data.count else { throw RunnerError(localized: "ZIP目録の長さが一致しません。") }
        // A file cannot also be a parent directory (including case-folded aliases).
        let files = Set(result.filter { !$0.directory }.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() })
        for entry in result {
            let parts = entry.name.split(separator: "/")
            for index in 1..<parts.count {
                guard !files.contains(parts.prefix(index).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()) else {
                    throw RunnerError(localized: "ZIP内でファイルとフォルダのパスが衝突しています。")
                }
            }
        }
        self.entries = result
        directoryOffset = offset
    }

    func contents(_ entry: Entry) throws -> Data {
        try Task.checkCancellation()
        guard entry.size <= Self.maximumFileBytes, entry.compressed <= Self.maximumFileBytes else {
            throw RunnerError(localized: "壁紙内の単一ファイルは64 MiBまでです。")
        }
        let header = try Self.read(handle, offset: entry.offset, count: 30)
        let nameSize = header.u16(26), extraSize = header.u16(28)
        let start = entry.offset + 30 + nameSize + extraSize
        guard header.u32(0) == 0x04034b50, header.u16(6) == entry.flags, header.u16(8) == entry.method,
              start + entry.compressed <= directoryOffset,
              try Self.read(handle, offset: entry.offset + 30, count: nameSize) == Data(entry.name.utf8) else {
            throw RunnerError(localized: "ZIPのローカルヘッダーが目録と一致しません。")
        }
        let compressed = try Self.read(handle, offset: start, count: entry.compressed)
        var output: Data
        if entry.method == 0 {
            guard entry.compressed == entry.size else { throw RunnerError(localized: "ZIPのサイズが一致しません。") }
            output = compressed
        } else {
            // One extra byte lets empty entries finish and detects understated sizes.
            output = Data(count: entry.size + 1)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw RunnerError(localized: "ZIP展開を初期化できません。")
            }
            defer { inflateEnd(&stream) }
            let status = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_in == entry.compressed, stream.total_out == entry.size else {
                throw RunnerError(localized: "ZIP展開に失敗しました。破損またはサイズ上限超過です。")
            }
            output.removeLast()
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard UInt32(crc) == entry.crc else { throw RunnerError(localized: "ZIPのCRC検証に失敗しました。") }
        try Task.checkCancellation()
        return output
    }

    private static func read(_ handle: FileHandle, offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw RunnerError(localized: "ZIPが途中で終了しています。") }
        return data
    }
}

private extension Data {
    func u16(_ offset: Int) -> Int { Int(self[offset]) | Int(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
