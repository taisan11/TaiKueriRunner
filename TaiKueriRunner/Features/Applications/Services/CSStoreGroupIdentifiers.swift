// Embedded-plist recovery adapted from kolbicz/WQFiles WQLaunchServices.m,
// revision 9dec88874235d41196da4e52485fbe0024b7a5fd (GPL-3.0-or-later).
import Foundation

enum CSStoreGroupIdentifiers {
    static func parse(_ input: Data) throws -> [String: Set<String>] {
        try Task.checkCancellation()
        let data = Data(input)
        guard data.count <= CSStoreParser.maximumBytes else { throw RunnerError(localized: "共有グループDBが上限を超えています。") }
        let needle = Data("/mobile/Containers/Shared/AppGroup/".utf8), magic = Data("bplist00".utf8)
        var cursor = 0, parsed = Set<Int>(), result: [String: Set<String>] = [:]
        var hits = 0, work = 0, nodes = 0
        func collect(_ object: Any, depth: Int) throws {
            guard depth <= 6 else { return }
            nodes += 1
            guard nodes <= 200_000 else { throw RunnerError(localized: "共有グループplistの項目数が上限を超えています。") }
            if let dictionary = object as? [String: Any] {
                for (key, value) in dictionary {
                    if let raw = value as? String, let path = LaunchServicesPaths.container(raw, root: AppGroupPaths.root),
                       plausibleIdentifier(key) {
                        result[path, default: []].insert(key)
                    } else { try collect(value, depth: depth + 1) }
                }
            } else if let array = object as? [Any] {
                for value in array { try collect(value, depth: depth + 1) }
            }
        }
        while cursor < data.count, let hit = data.range(of: needle, in: cursor..<data.count) {
            try Task.checkCancellation()
            cursor = hit.upperBound
            hits += 1
            guard hits <= 100_000 else { throw RunnerError(localized: "共有グループDBの候補数が上限を超えています。") }
            guard let header = data.range(of: magic, options: .backwards,
                                          in: max(0, hit.lowerBound - 16_384)..<hit.lowerBound),
                  parsed.insert(header.lowerBound).inserted else { continue }
            guard parsed.count <= 4096 else { throw RunnerError(localized: "共有グループplistの数が上限を超えています。") }
            let start = header.lowerBound, limit = min(65_536, data.count - start)
            var minimum = max(40, hit.upperBound - start + 1), attempts = 0
            while minimum <= limit, attempts < 8 {
                var candidate: Int?
                for length in minimum...limit {
                    work += 1
                    if work.isMultiple(of: 4096) { try Task.checkCancellation() }
                    guard work <= 32 * 1024 * 1024 else { throw RunnerError(localized: "共有グループplistの探索量が上限を超えています。") }
                    let t = start + length - 32
                    guard data[t..<(t + 5)].allSatisfy({ $0 == 0 }) else { continue }
                    let width = UInt64(data[t + 6]), ref = data[t + 7]
                    guard (1...8).contains(width), (1...8).contains(ref) else { continue }
                    func be(_ offset: Int) -> UInt64 {
                        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
                    }
                    let objects = be(t + 8), top = be(t + 16), table = be(t + 24)
                    guard objects > 0, objects <= 100_000, top < objects, table >= 8,
                          table <= UInt64(length),
                          table + objects * width + 32 == UInt64(length) else { continue }
                    candidate = length
                    break
                }
                guard let length = candidate else { break }
                attempts += 1
                if let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start..<(start + length)), format: nil) {
                    try collect(plist, depth: 0)
                    break
                }
                minimum = length + 1
            }
        }
        return result
    }

    static func plausibleIdentifier(_ value: String) -> Bool {
        (3...255).contains(value.utf8.count) && value.contains(".") &&
        !value.hasPrefix(".") && !value.hasSuffix(".") &&
        value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
}
