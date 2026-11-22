import Foundation

struct FileBackupManifest: Codable, Sendable {
    let version: Int
    let created: Date
    let operation: String
    let kind: String?
    let sourcePath: String?
    let destinationPath: String?
    let destinationWasAbsent: Bool
    let parent: FileBackupStore.Snapshot?
    let entries: [String: FileBackupStore.Snapshot]
    let hashes: [String: String]?
    var wallpaper: WallpaperBackupMetadata? = nil

    var operationKind: String {
        if let kind { return kind }
        // Previous releases stored only Japanese display names (manifest v1).
        switch operation {
        case "テキストを保存": return "saveText"
        case "フォルダを作成": return "createFolder"
        case "名前を変更": return "rename"
        case "削除": return "delete"
        case "ファイルをインポート": return "importFile"
        default: return "unknown"
        }
    }
}

struct FileBackupOutcome: Codable, Sendable {
    let succeeded: Bool
    let changedPath: String?
    let snapshot: [String: FileBackupStore.Snapshot]?
}

enum BackupRestoration: Sendable {
    case original(path: String), removeCreated(path: String)
    var path: String { switch self { case .original(let path), .removeCreated(let path): path } }
}

struct FileBackupRecord: Identifiable, Sendable {
    let id: String
    let directory: URL
    let manifest: FileBackupManifest
    let outcome: FileBackupOutcome?
    var payload: URL { directory.appendingPathComponent("original") }
    var targetPath: String { (try? restoration().path) ?? manifest.sourcePath ?? manifest.destinationPath ?? L("不明") }
    var size: Int64 { manifest.entries.values.filter(\.isRegular).reduce(0) { $0 + $1.size } }
    var status: String { outcome.map { $0.succeeded ? L("操作完了") : L("操作未完了") } ?? (manifest.version == 1 ? L("旧形式 / 完了状態不明") : L("完了記録なし")) }

    func restoration() throws -> BackupRestoration {
        switch manifest.operationKind {
        case "saveText", "savePropertyList", "replaceKeypad", "delete", "rename":
            guard let path = manifest.sourcePath, manifest.entries["."] != nil else { throw RunnerError(localized: "元データの記録がありません。") }
            return .original(path: path)
        case "createFolder", "importFile", "addWallpaper":
            guard let path = manifest.destinationPath, outcome?.succeeded == true, outcome?.snapshot?.isEmpty == false else {
                throw RunnerError(localized: "作成後の検証記録がないため、自動で削除して戻すことはできません。保存データをファイルで確認してください。")
            }
            return .removeCreated(path: path)
        case "restoreBackup":
            if let path = manifest.sourcePath, manifest.entries["."] != nil { return .original(path: path) }
            guard let path = manifest.destinationPath, outcome?.succeeded == true, outcome?.snapshot?.isEmpty == false else { throw RunnerError(localized: "この復元操作を戻すための記録がありません。") }
            return .removeCreated(path: path)
        default: throw RunnerError(localized: "このバックアップの操作形式は復元に対応していません。")
        }
    }

    var restorationNote: String {
        guard let plan = try? restoration() else { return L("この記録は自動復元できません。元データをファイルで確認できます。") }
        switch plan {
        case .original:
            return L("元のパスへデータを復元します。既存ファイルは上書き前に再バックアップします。既存フォルダとの結合・置換はしません。") +
                (manifest.operationKind == "rename" ? L(" 名前変更後の項目は削除せず残します。") : "")
        case .removeCreated:
            return L("この操作で作成した項目を削除して、作成前の状態へ戻します。作成後に内容・属性が変わっていた場合は拒否します。削除前にもバックアップします。")
        }
    }
}

struct FileBackupListing: Sendable {
    let records: [FileBackupRecord]
    let unreadableCount: Int
}

struct FileBackupDeletion: Sendable {
    let removed: [String]
    let failed: [String]
    let freedBytes: Int64
}
