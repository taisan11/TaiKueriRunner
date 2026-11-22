import Foundation

// Export the exact device PNG bytes, never draft artwork or a thumbnail.
// Only the injected reader accesses device files; ZIP creation sees private copies.
enum KeypadExport {
    static let maximumBytes = 256 * 1024 * 1024
    static let maximumArchiveBytes = maximumBytes + 2 * 1024 * 1024

    static func relativePath(_ file: KeypadCacheFile) throws -> String {
        let url = URL(fileURLWithPath: file.path)
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard folder == "TelephonyUI-10",
              let name = KeypadAssetName(url.lastPathComponent), name == file.name else {
            throw RunnerError(localized: "保存対象のキー画像名・フォルダが不正です。")
        }
        return folder + "/" + url.lastPathComponent
    }

    static func stage(files: [KeypadCacheFile], archive: Bool,
                      temporaryRoot: URL = FileManager.default.temporaryDirectory,
                      read: @Sendable (KeypadCacheFile) async throws -> Data) async throws -> StagedDocumentPreview {
        try Task.checkCancellation()
        guard !files.isEmpty, files.count <= 1500, archive || files.count == 1,
              Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ $0.snapshot.isRegular && $0.snapshot.size > 0 && $0.snapshot.size <= KeypadImage.maximumBytes }),
              files.reduce(Int64(0), { $0 + $1.snapshot.size }) <= maximumBytes else {
            throw RunnerError(localized: "保存対象は1〜1,500枚・単一16 MiB・合計256 MiBまでです。")
        }
        let paths = try files.map(relativePath)
        guard Set(paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == files.count else {
            throw RunnerError(localized: "保存先の画像名が重複しています。適用先ごとに保存してください。")
        }
        let manager = FileManager.default
        let directory = temporaryRoot.appendingPathComponent("KeypadExport-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let payload = directory.appendingPathComponent("Images", isDirectory: true)
            if archive { try manager.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            var single: URL?
            for (file, relative) in zip(files, paths) {
                try Task.checkCancellation()
                let data = try await read(file)
                try Task.checkCancellation()
                guard data.count == file.snapshot.size else { throw RunnerError(localized: "保存中にキー画像のサイズが変更されました。再読み込みしてください。") }
                let dimensions = try KeypadImage.pngDimensions(data)
                guard dimensions.0 == file.width, dimensions.1 == file.height else {
                    throw RunnerError(localized: "保存中にキー画像の寸法が変更されました。再読み込みしてください。")
                }
                let url = archive ? payload.appendingPathComponent(relative) :
                    directory.appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent)
                if archive { try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                try data.write(to: url, options: .withoutOverwriting)
                single = url
            }
            let output: URL
            if archive {
                output = directory.appendingPathComponent("Keypad-phone-images.zip")
                try StoredZIPArchive.write(directory: payload, to: output, maximumBytes: maximumArchiveBytes)
                try manager.removeItem(at: payload)
            } else { output = single! }
            try Task.checkCancellation()
            return StagedDocumentPreview(url: output, directory: directory)
        } catch {
            // Only remove this invocation's new private directory.
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
