import Foundation
#if SWIFT_PACKAGE
import NativeBridge
#endif

actor PathScanner {
    func scan(path: String, maximum: UInt64, progress: @Sendable (Double, [String]) async -> Void) async throws -> [String] {
        let path = try FileRules.canonical(path)
        guard maximum > 0, maximum <= 100_000_000 else { throw RunnerError(localized: "inode上限は1〜100,000,000で指定してください。") }
        var found = Set<String>()
        let chunk: UInt64 = 4096
        var first: UInt64 = 1
        while first <= maximum {
            try Task.checkCancellation()
            let last = min(first + chunk - 1, maximum)
            guard let paths = autoreleasepool(invoking: { TKEnumeratePaths(path, first, last) }) else {
                throw RunnerError(localized: "列挙対象のボリュームを確認できません。親ディレクトリのパスを確認してください。")
            }
            found.formUnion(paths)
            if first == 1 || last == maximum || (first - 1) % (chunk * 16) == 0 {
                await progress(Double(last) / Double(maximum), found.sorted())
            }
            first = last + 1
            await Task.yield()
        }
        try Task.checkCancellation()
        return found.sorted()
    }

    func baselineInode() throws -> UInt64 {
        let files = FileManager.default
        let url = files.temporaryDirectory.appendingPathComponent("inode-baseline-\(UUID().uuidString)")
        try Data([0]).write(to: url)
        defer { try? files.removeItem(at: url) }
        let attrs = try files.attributesOfItem(atPath: url.path)
        guard let value = attrs[.systemFileNumber] as? NSNumber else { throw RunnerError(localized: "inodeを取得できませんでした。") }
        return value.uint64Value
    }
}
