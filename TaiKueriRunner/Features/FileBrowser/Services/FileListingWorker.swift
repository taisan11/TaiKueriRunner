import Foundation

// Filtering and sorting do not touch the filesystem and never run on the UI actor.
actor FileListingWorker {
    func apply(_ entries: [FileEntry], search: String, options: FileListingOptions) throws -> [FileEntry] {
        try Task.checkCancellation()
        var visible: [FileEntry] = []
        visible.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if search.isEmpty || entry.name.localizedStandardContains(search) { visible.append(entry) }
        }
        visible.sort(by: options.precedes)
        try Task.checkCancellation()
        return visible
    }
}
