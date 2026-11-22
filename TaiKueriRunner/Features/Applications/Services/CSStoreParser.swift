// CSStore layouts and decoding approach adapted from kolbicz/WQFiles
// WQLaunchServices.m, revision f149ba83050ef53ebdb9b73f2e83447f88057965.
// GPL-3.0-or-later. This is a bounded Swift implementation, not a SQLite reader.
import Foundation

enum CSStoreParser {
    static let maximumBytes = 64 * 1024 * 1024
    private static let maximumRecords = 100_000
    private static let maximumStrings = 200_000
    private static let maximumStringBytes = 8 * 1024 * 1024

    struct Layout {
        let name: String
        let size: Int
        let bundleID: Int
        let container: Int
        let bundleName: Int
        let displayName: Int
        let pluginSize: Int
        let pluginID: Int
        let pluginContainer: Int
    }

    static let layouts = [
        Layout(name: "27.0", size: 0x250, bundleID: 0x0c, container: 0x68, bundleName: 0x6c, displayName: 0x74, pluginSize: 0x118, pluginID: 0x00, pluginContainer: 0x54),
        Layout(name: "26", size: 0x23c, bundleID: 0x0c, container: 0x64, bundleName: 0x68, displayName: 0x70, pluginSize: 0x104, pluginID: 0x00, pluginContainer: 0x50),
        Layout(name: "27.2", size: 0x25c, bundleID: 0x0c, container: 0x6c, bundleName: 0x70, displayName: 0x78, pluginSize: 0x120, pluginID: 0x00, pluginContainer: 0x58),
        Layout(name: "27.2b", size: 0x25c, bundleID: 0x10, container: 0x6c, bundleName: 0x70, displayName: 0x78, pluginSize: 0x120, pluginID: 0x04, pluginContainer: 0x58),
        Layout(name: "27.2c", size: 0x25c, bundleID: 0x0c, container: 0x6c, bundleName: 0x70, displayName: 0x78, pluginSize: 0x120, pluginID: 0x04, pluginContainer: 0x58),
        Layout(name: "27.2d", size: 0x25c, bundleID: 0x10, container: 0x6c, bundleName: 0x70, displayName: 0x78, pluginSize: 0x120, pluginID: 0x00, pluginContainer: 0x58)
    ]

    private struct Record {
        let kind: ApplicationKind
        let id: UInt32
        let container: UInt32
        let name: UInt32
        let display: UInt32
        let bundle: UInt32
    }

    static func parse(_ input: Data) throws -> ParsedApplicationCatalog {
        guard input.count >= 0x1000, input.count <= maximumBytes, input.prefix(4) == Data("bdsl".utf8) else {
            throw RunnerError(localized: "有効なLaunchServices CSStoreではありません（bdsl形式・4 KiB〜64 MiBが必要です）。")
        }
        let data = Data(input) // Reset indices when the caller supplies a Data slice.
        try Task.checkCancellation()
        let groupIdentifiers = try CSStoreGroupIdentifiers.parse(data)
        let heap = data.range(of: Data("<string>".utf8))?.lowerBound ?? 0
        return try data.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
            func stringID(_ reference: UInt32) -> UInt32? {
                reference > 0 && reference & 3 == 0 && reference >> 2 < 0x01000000 ? reference >> 2 : nil
            }
            var records = Array(repeating: [Record](), count: layouts.count)
            var needed = Set<UInt32>()
            var recordCount = 0
            for offset in stride(from: 0, through: data.count - 8, by: 4) {
                if offset & 0xffff == 0 { try Task.checkCancellation() }
                let size = Int(word(offset + 4)), body = offset + 8
                guard size <= data.count - body else { continue }
                for (index, layout) in layouts.enumerated() where size == layout.size || size == layout.pluginSize {
                    let record: Record
                    if size == layout.size {
                        record = Record(kind: .application, id: word(body + layout.bundleID), container: word(body + layout.container),
                                        name: word(body + layout.bundleName), display: word(body + layout.displayName), bundle: word(body))
                    } else {
                        record = Record(kind: .appExtension, id: word(body + layout.pluginID), container: word(body + layout.pluginContainer), name: 0, display: 0, bundle: 0)
                    }
                    guard stringID(record.id) != nil else { continue }
                    recordCount += 1
                    guard recordCount <= maximumRecords else { throw RunnerError(localized: "CSStoreのレコード数が安全上限を超えています。") }
                    records[index].append(record)
                    for reference in [record.id, record.container, record.name, record.display, record.bundle] {
                        if let id = stringID(reference) { needed.insert(id) }
                    }
                }
            }
            guard !needed.isEmpty, needed.count <= maximumStrings else { throw RunnerError(localized: "対応するCSStoreレコードがありません。OSのDB形式が変更された可能性があります。") }

            var strings: [UInt32: String] = [:], paths: [UInt32: String] = [:], bundles: [UInt32: String] = [:]
            var insideHeap = Set<UInt32>(), ambiguousPaths = Set<UInt32>(), ambiguousBundles = Set<UInt32>()
            var groups = Set(groupIdentifiers.keys), decodedCount = 0, decodedBytes = 0
            for offset in stride(from: 0, through: data.count - 9, by: 4) {
                if offset & 0xffff == 0 { try Task.checkCancellation() }
                let id = word(offset)
                guard needed.contains(id) else { continue }
                let length = Int(word(offset + 4))
                guard length > 0, length < 0x800, length < data.count - offset - 8,
                      length.isMultiple(of: 4) || bytes[offset + 8 + length] == 0 else { continue }
                let contents = UnsafeRawBufferPointer(rebasing: bytes[(offset + 8)..<(offset + 8 + length)])
                guard !contents.contains(0), let string = String(bytes: contents, encoding: .utf8) else { continue }
                decodedCount += 1; decodedBytes += length
                guard decodedCount <= maximumStrings, decodedBytes <= maximumStringBytes else { throw RunnerError(localized: "CSStoreの文字列が安全上限を超えています。") }
                if strings[id] == nil || (offset >= heap && !insideHeap.contains(id)) { strings[id] = string }
                if offset >= heap { insideHeap.insert(id) }
                if let path = LaunchServicesPaths.dataContainer(string) {
                    if let old = paths[id], old != path { ambiguousPaths.insert(id) }
                    else { paths[id] = path }
                }
                if let path = LaunchServicesPaths.bundlePath(string) {
                    if let old = bundles[id], old != path { ambiguousBundles.insert(id) }
                    else { bundles[id] = path }
                }
                if let path = LaunchServicesPaths.container(string, root: LaunchServicesPaths.groupRoot) { groups.insert(path) }
            }
            // Group paths need not be referenced by a Bundle record. Decode only
            // exact, bounded UUID paths from the store; do not infer their owners.
            let groupNeedle = Data((LaunchServicesPaths.groupRoot + "/").utf8)
            var groupOffset = 0
            while groupOffset < data.count, let range = data.range(of: groupNeedle, in: groupOffset..<data.count) {
                try Task.checkCancellation()
                let start = range.upperBound
                if start + 36 <= data.count,
                   (start + 36 == data.count || data[start + 36] == 0 || data[start + 36] == 47),
                   let uuid = String(data: data[start..<(start + 36)], encoding: .ascii), UUID(uuidString: uuid) != nil {
                    groups.insert(LaunchServicesPaths.groupRoot + "/" + uuid.uppercased())
                }
                groupOffset = start
                guard groups.count <= maximumRecords else { throw RunnerError(localized: "共有コンテナ数が安全上限を超えています。") }
            }

            var best: ParsedApplicationCatalog?
            var bestMappingCount = -1
            var bestNameCount = -1
            for (index, layout) in layouts.enumerated() {
                var claims: [String: (String, ApplicationKind)] = [:]
                var conflicts = Set<String>()
                var names: [String: String] = [:], bundlePaths: [String: String] = [:]
                for record in records[index] {
                    guard let id = stringID(record.id), let bid = strings[id], validBundleID(bid) else { continue }
                    if let display = stringID(record.display).flatMap({ strings[$0] }).flatMap(safeName) { names[bid] = names[bid] ?? display }
                    else if let name = stringID(record.name).flatMap({ strings[$0] }).flatMap(safeName) { names[bid] = names[bid] ?? name }
                    if let ref = stringID(record.bundle), !ambiguousBundles.contains(ref) { bundlePaths[bid] = bundles[ref] }
                    guard let ref = stringID(record.container), !ambiguousPaths.contains(ref), let path = paths[ref],
                          path.hasPrefix((record.kind == .application ? LaunchServicesPaths.applicationRoot : LaunchServicesPaths.extensionRoot) + "/") else { continue }
                    if let previous = claims[path], previous.0 != bid { conflicts.insert(path) }
                    else { claims[path] = (bid, record.kind) }
                }
                for path in conflicts { claims.removeValue(forKey: path) }
                var grouped: [String: [String]] = [:], identities: [String: (String, ApplicationKind)] = [:]
                for (path, claim) in claims {
                    let key = "\(claim.1.rawValue):\(claim.0)"
                    grouped[key, default: []].append(path)
                    identities[key] = claim
                }
                let applications = grouped.compactMap { key, paths -> CatalogApplication? in
                    guard let (bid, kind) = identities[key] else { return nil }
                    return CatalogApplication(bundleID: bid, name: names[bid] ?? builtinNames[bid] ?? bid, kind: kind,
                                              containerPaths: paths.sorted(), bundlePath: bundlePaths[bid])
                }.sorted {
                    let names = $0.name.localizedStandardCompare($1.name)
                    return names == .orderedSame ? $0.id < $1.id : names == .orderedAscending
                }
                if claims.count > bestMappingCount || (claims.count == bestMappingCount && names.count > bestNameCount) {
                    bestMappingCount = claims.count
                    bestNameCount = names.count
                    best = ParsedApplicationCatalog(layout: layout.name, applications: applications, sharedGroupPaths: groups.sorted(),
                                                    ambiguousContainerCount: conflicts.count + ambiguousPaths.count,
                                                    sharedGroupIdentifiers: groupIdentifiers)
                }
            }
            guard let best, !best.applications.isEmpty else { throw RunnerError(localized: "Bundle IDとコンテナを対応付けできません。未対応・破損したCSStoreの可能性があります。") }
            try Task.checkCancellation()
            return best
        }
    }

    static func validBundleID(_ string: String) -> Bool {
        string.utf8.count > 2 && string.utf8.count <= 255 && string.contains(".") && !string.hasPrefix(".") &&
        string.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }

    static func safeName(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .format, .lineSeparator, .paragraphSeparator: return "�"
            default: return String(scalar)
            }
        }.joined().precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scalars.isEmpty, scalars.count <= 256, !scalars.hasPrefix("/"), !scalars.contains(".app/"),
              scalars.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return scalars
    }

    private static let builtinNames = ["com.apple.mobilesafari": "Safari", "com.apple.Preferences": L("設定"), "com.apple.camera": L("カメラ"),
                                       "com.apple.mobilenotes": L("メモ"), "com.apple.MobileSMS": L("メッセージ"), "com.apple.mobilemail": L("メール"),
                                       "com.apple.Music": L("ミュージック"), "com.apple.mobileslideshow": L("写真"), "com.apple.AppStore": "App Store",
                                       "com.apple.DocumentsApp": L("ファイル"), "com.apple.Maps": L("マップ"), "com.apple.mobilephone": L("電話")]
}
