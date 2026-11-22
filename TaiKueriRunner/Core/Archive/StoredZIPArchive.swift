import Foundation
import Darwin

// A bounded, streaming ZIP (method 0 / stored) writer. No file coordinator,
// provider daemon, source permissions, compression subprocess or third-party code.
enum StoredZIPArchive {
    private struct Entry {
        let name: Data
        let directory: Bool
        let offset: UInt32
        let size: UInt32
        let crc: UInt32
        var flags: UInt16 { directory ? 0x0800 : 0x0808 } // UTF-8; file data descriptor
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }

    static func write(directory: URL, to destination: URL, maximumBytes: Int, report: Data? = nil) throws {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= ApplicationDataExport.maximumArchiveBytes,
              (report?.count ?? 0) <= 64 * 1024 * 1024 else { throw RunnerError(localized: "ZIPサイズ上限が不正です。") }
        let source = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard source != "/", target != source, !target.hasPrefix(source + "/") else {
            throw RunnerError(localized: "ZIPを入力フォルダの中には作成できません。")
        }
        let before = try inventory(directory)
        guard before["."]?.isDirectory == true else { throw RunnerError(localized: "ZIPの入力は通常のフォルダにしてください。") }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        var position = 0
        func write(_ data: Data) throws {
            try Task.checkCancellation()
            guard data.count <= maximumBytes - position else { throw RunnerError(localized: "完成ZIPがサイズ上限を超えています。") }
            try output.write(contentsOf: data)
            position += data.count
        }

        var entries: [Entry] = []
        for relative in before.keys.sorted() + (report == nil ? [] : ["ExportReport.json"]) {
            try Task.checkCancellation()
            let isReport = relative == "ExportReport.json"
            let item = before[relative]
            let isDirectory = item?.isDirectory == true
            let size = isReport ? Int64(report!.count) : (item?.isRegular == true ? item!.size : 0)
            let components = relative == "." ? [] : String(relative.dropFirst(2)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard isReport || ((relative == "." || relative.hasPrefix("./")) && components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
            })) else { throw RunnerError(localized: "ZIPとして安全に表現できないファイル名があります。") }
            let name = isReport ? Data("ExportReport.json".utf8) : Data((["Data"] + components).joined(separator: "/").appending(isDirectory ? "/" : "").utf8)
            guard name.count <= Int(UInt16.max) else { throw RunnerError(localized: "ZIPのファイル名が長すぎます。") }
            let offset = UInt32(position)
            var header = Data()
            header.zip32(0x04034b50); header.zip16(20)
            header.zip16(isDirectory ? 0x0800 : 0x0808)
            header.zip16(0); header.zip16(0); header.zip16(0x0021) // stored; 1980-01-01
            header.zip32(0); header.zip32(0); header.zip32(0)
            header.zip16(UInt16(name.count)); header.zip16(0); header.append(name)
            try write(header)
            var crc = UInt32.max
            if !isDirectory {
                if isReport {
                    let report = report!
                    for offset in stride(from: 0, to: report.count, by: 1_048_576) {
                        let data = report[offset..<min(offset + 1_048_576, report.count)]
                        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
                        try write(data)
                    }
                } else {
                    let file = directory.appendingPathComponent(components.joined(separator: "/"))
                    guard try FileBackupStore.Snapshot(path: file.path) == item else { throw changedError() }
                    try StableFileReader.withFile(path: file.path, maximumBytes: Int(ApplicationDataExport.Limits().maximumBytes)) { input, count in
                        guard Int64(count) == size else { throw changedError() }
                        var copied = 0
                        while copied < count {
                            try Task.checkCancellation()
                            let data = try input.read(upToCount: min(1_048_576, count - copied)) ?? Data()
                            guard !data.isEmpty else { throw changedError() }
                            for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
                            try write(data)
                            copied += data.count
                        }
                        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw changedError() }
                    }
                }
                crc ^= UInt32.max
                var descriptor = Data()
                descriptor.zip32(0x08074b50); descriptor.zip32(crc)
                descriptor.zip32(UInt32(size)); descriptor.zip32(UInt32(size))
                try write(descriptor)
            } else { crc = 0 }
            entries.append(Entry(name: name, directory: isDirectory, offset: offset, size: UInt32(size), crc: crc))
        }
        guard try inventory(directory) == before, entries.count <= Int(UInt16.max) else { throw changedError() }
        let centralOffset = UInt32(position)
        for entry in entries {
            var header = Data()
            header.zip32(0x02014b50); header.zip16(0x0314); header.zip16(20)
            header.zip16(entry.flags); header.zip16(0); header.zip16(0); header.zip16(0x0021)
            header.zip32(entry.crc); header.zip32(entry.size); header.zip32(entry.size)
            header.zip16(UInt16(entry.name.count)); header.zip16(0); header.zip16(0)
            header.zip16(0); header.zip16(0)
            header.zip32(entry.directory ? 0x41c00010 : 0x81800000) // Unix 0700 dir / 0600 file
            header.zip32(entry.offset); header.append(entry.name)
            try write(header)
        }
        var end = Data()
        end.zip32(0x06054b50); end.zip16(0); end.zip16(0)
        end.zip16(UInt16(entries.count)); end.zip16(UInt16(entries.count))
        end.zip32(UInt32(position) - centralOffset); end.zip32(centralOffset); end.zip16(0)
        try write(end)
        try output.synchronize()
        try Task.checkCancellation()
        completed = true
    }

    static func inventory(_ directory: URL) throws -> [String: FileBackupStore.Snapshot] {
        let limits = ApplicationDataExport.Limits()
        var result: [String: FileBackupStore.Snapshot] = [:]
        var bytes: Int64 = 0
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try Task.checkCancellation()
            let item = try FileBackupStore.Snapshot(path: url.path)
            guard item.isRegular || item.isDirectory else { throw RunnerError(localized: "ZIPの入力にリンク・特殊ファイルは使用できません。") }
            guard depth <= limits.maximumDepth, result.count < limits.maximumItems,
                  !item.isRegular || (item.size >= 0 && item.size <= limits.maximumBytes - bytes) else {
                throw RunnerError(localized: "ZIPの入力上限（2 GiB・50,000項目・深さ128）を超えています。")
            }
            if item.isRegular { bytes += item.size }
            result[relative] = item
            if item.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
        }
        try visit(directory, relative: ".", depth: 0)
        return result
    }

    private static func changedError() -> RunnerError { RunnerError(localized: "ZIP作成中に作業用コピーが変更されました。") }
}

private extension Data {
    mutating func zip16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func zip32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
