import Foundation

struct KeypadCacheFile: Sendable {
    let path: String
    let name: KeypadAssetName
    let snapshot: FileBackupStore.Snapshot
    let directory: FileBackupStore.Snapshot
    let width: Int
    let height: Int
}

struct KeypadLibrarySnapshot: Sendable {
    let files: [KeypadCacheFile]
    let previews: [KeypadKey: Data]
    let issues: [String]
    var directoryPath: String? = nil
}

struct KeypadWriteEntry: Sendable {
    let file: KeypadCacheFile
    let data: Data
}

struct KeypadWritePlan: Sendable {
    let entries: [KeypadWriteEntry]
}

actor KeypadLibraryWorker {
    let files: FileAccessManager
    private var stagedExports = Set<URL>()
    init(files: FileAccessManager) { self.files = files }

    func stageExport(_ entries: [KeypadCacheFile], archive: Bool) async throws -> StagedDocumentPreview {
        let staged = try await KeypadExport.stage(files: entries, archive: archive, temporaryRoot: files.temporaryRoot) { [files] entry in
            try await files.readKeypadPreview(entry)
        }
        // No await between ownership registration and returning the copy.
        stagedExports.insert(staged.directory)
        return staged
    }

    func closeExport(_ staged: StagedDocumentPreview) {
        if stagedExports.remove(staged.directory) != nil { try? FileManager.default.removeItem(at: staged.directory) }
    }

    func load(directories: [String]) async throws -> KeypadLibrarySnapshot {
        var result: [KeypadCacheFile] = [], previews: [KeypadKey: Data] = [:], issues: [String] = []
        var readableDirectories = Set<String>()
        for path in directories {
            try Task.checkCancellation()
            let names: [String]
            do {
                names = try await files.readKeypadDirectory(path)
                readableDirectories.insert(try WallpaperPaths.normalized(path))
            }
            catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(path): \(error.localizedDescription)"); continue }
            for name in names.sorted() where KeypadAssetName(name) != nil {
                try Task.checkCancellation()
                guard result.count < 1500 else { throw RunnerError(localized: "端末のキー画像は1,500ファイルまでです。") }
                do {
                    let entry = try await files.readKeypadFile(path: path + "/" + name)
                    result.append(entry)
                    if previews[entry.name.key] == nil {
                        let data = try await files.readKeypadPreview(entry)
                        previews[entry.name.key] = try WallpaperThumbnail.make(data)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { if issues.count < 20 { issues.append("\(name): \(error.localizedDescription)") } }
            }
        }
        return KeypadLibrarySnapshot(files: result, previews: previews, issues: issues,
                                     directoryPath: readableDirectories.count == 1 ? readableDirectories.first : nil)
    }

    func readTheme(_ url: URL) throws -> KeypadTheme { try KeypadTheme.inspect(url) }

    func readImage(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try StableFileReader.read(path: url.path, maximumBytes: KeypadImage.maximumBytes) { $0 }
        try KeypadImage.validate(data)
        return data
    }

    func plan(snapshot: KeypadLibrarySnapshot, theme: KeypadTheme?,
              overrides: [KeypadKey: Data], options: KeypadRenderOptions) throws -> KeypadWritePlan {
        var entries: [KeypadWriteEntry] = [], bytes = 0
        // Reuse PNGs across matching locale/appearance variants.
        struct Identity: Hashable { let source: String; let width: Int; let height: Int }
        var rendered: [Identity: Data] = [:]
        for file in snapshot.files {
            try Task.checkCancellation()
            let asset = theme?.asset(for: file.name.key, matching: file.name)
            guard let data = overrides[file.name.key] ?? asset?.data else { continue }
            let width = file.width, height = file.height
            let source = overrides[file.name.key] != nil ? "override/" + file.name.key.rawValue : "theme/" + asset!.path
            let identity = Identity(source: source, width: width, height: height)
            let png: Data
            if let existing = rendered[identity] { png = existing }
            else {
                png = try KeypadImage.render(data, width: width, height: height, circular: options.circular)
                rendered[identity] = png
            }
            bytes += png.count
            guard bytes <= Int(FileBackupStore.maximumBytes), entries.count < 1500 else { throw RunnerError(localized: "適用画像の合計が256 MiB・1,500ファイルの上限を超えています。") }
            entries.append(KeypadWriteEntry(file: file, data: png))
        }
        guard !entries.isEmpty else { throw RunnerError(localized: "端末のキャッシュに対応する変更がありません。テーマまたはキー画像を選択してください。") }
        return KeypadWritePlan(entries: entries)
    }

    func preview(theme: KeypadTheme?, overrides: [KeypadKey: Data], options: KeypadRenderOptions) throws -> [KeypadKey: Data] {
        var result: [KeypadKey: Data] = [:]
        for key in KeypadKey.allCases {
            if let data = overrides[key] ?? theme?.image(for: key) {
                result[key] = try KeypadImage.render(data, width: 240, height: 240, circular: options.circular)
            }
        }
        return result
    }
}

enum KeypadWriteTransaction {
    // Every backup is complete before the first mutation. Not an atomic group:
    // partial writes are reported explicitly, never as an overall success.
    static func execute(_ entries: [KeypadWriteEntry], store: FileBackupStore, userConsented: Bool,
                        validate: (KeypadCacheFile) throws -> Void,
                        backup: (KeypadWriteEntry) throws -> FileBackupStore.Backup,
                        write: (KeypadWriteEntry, FileBackupStore.Backup) throws -> Void) throws -> FileWriteReceipt {
        guard userConsented else { throw RunnerError(localized: "操作ごとのユーザー同意が必要です。") }
        guard !entries.isEmpty, entries.count <= 1500, Set(entries.map { $0.file.path }).count == entries.count,
              entries.reduce(Int64(0), { $0 + $1.file.snapshot.size }) <= FileBackupStore.maximumBytes,
              entries.reduce(0, { $0 + $1.data.count }) <= Int(FileBackupStore.maximumBytes) else {
            throw RunnerError(localized: "キーパッドの変更対象が不正または上限超過です。")
        }
        var backups: [FileBackupStore.Backup] = [], written = 0
        do {
            for entry in entries {
                try Task.checkCancellation()
                try validate(entry.file)
                try store.protect(URL(fileURLWithPath: entry.file.path))
                guard try FileBackupStore.Snapshot(path: entry.file.path) == entry.file.snapshot else {
                    throw RunnerError(localized: "キー画像が外部で変更されました。一覧を再読み込みしてください。")
                }
                backups.append(try backup(entry))
            }
            for (entry, backup) in zip(entries, backups) {
                try validate(entry.file)
                guard backup.snapshot["."] == entry.file.snapshot,
                      try FileBackupStore.Snapshot(path: entry.file.path) == entry.file.snapshot else {
                    throw RunnerError(localized: "バックアップ後にキー画像が変更されました。")
                }
            }
            for (entry, backup) in zip(entries, backups) {
                try Task.checkCancellation()
                try validate(entry.file)
                try write(entry, backup)
                written += 1
                try store.finish(backup, changedPath: entry.file.path, succeeded: true)
            }
        } catch {
            for backup in backups.dropFirst(written) { try? store.finish(backup, changedPath: nil, succeeded: false) }
            throw RunnerError(L("キーパッドの変更完了: \(String(describing: written))/\(String(describing: entries.count))ファイル。途中の失敗やキャンセルは自動で巻き戻しません。\n\(String(describing: error.localizedDescription))\n保存済みバックアップ: \(String(describing: backups.map { $0.directory.lastPathComponent }.joined(separator: ", ")))"))
        }
        return FileWriteReceipt(backupDirectory: backups[0].directory, title: L("キーパッドを変更（\(String(describing: written))ファイル）"))
    }
}
