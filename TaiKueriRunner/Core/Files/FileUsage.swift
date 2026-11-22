import Foundation

// Read-only size measurement for the app's own cache and backup directories.
// Symbolic links are counted as links and never followed.
enum FileUsage {
    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

    static func bytes(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true { return max(0, Int64(values.fileSize ?? 0)) }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                               options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isRegularFile == true, childValues.isSymbolicLink != true else { continue }
            total += max(0, Int64(childValues.fileSize ?? 0))
        }
        return total
    }
}
