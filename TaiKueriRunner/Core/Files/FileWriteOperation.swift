import Foundation

enum FileWriteOperation: Sendable {
    case saveText(path: String, text: String, original: String)
    case createFolder(name: String, directory: String)
    case rename(path: String, name: String)
    case delete(path: String)
    case importFile(source: URL, directory: String)
    case addWallpaper(source: URL, directory: String)
    case savePropertyList(path: String, data: Data, original: Data)
    // Backup metadata only. Mutations require the dedicated validated batch plan.
    case replaceKeypad(path: String)
    case restoreBackup(id: String)

    var title: String {
        switch self {
        case .saveText: L("テキストを保存")
        case .createFolder: L("フォルダを作成")
        case .rename: L("名前を変更")
        case .delete: L("削除")
        case .importFile: L("ファイルをインポート")
        case .addWallpaper: L("壁紙を追加")
        case .savePropertyList: L("Plistを保存")
        case .replaceKeypad: L("キーパッド画像を変更")
        case .restoreBackup: L("バックアップを復元")
        }
    }

    var kind: String {
        switch self {
        case .saveText: "saveText"
        case .createFolder: "createFolder"
        case .rename: "rename"
        case .delete: "delete"
        case .importFile: "importFile"
        case .addWallpaper: "addWallpaper"
        case .savePropertyList: "savePropertyList"
        case .replaceKeypad: "replaceKeypad"
        case .restoreBackup: "restoreBackup"
        }
    }

    func paths() throws -> (source: URL?, destination: URL?) {
        switch self {
        case let .saveText(path, _, _):
            let url = URL(fileURLWithPath: try FileRules.canonical(path))
            return (url, url)
        case let .savePropertyList(path, _, _):
            let url = URL(fileURLWithPath: try FileRules.canonical(path))
            return (url, url)
        case let .replaceKeypad(path):
            try KeypadPaths.validateFile(path)
            let url = URL(fileURLWithPath: try WallpaperPaths.normalized(path))
            return (url, url)
        case let .createFolder(name, directory):
            return (nil, try FileRules.child(name, in: directory))
        case let .rename(path, name):
            let url = URL(fileURLWithPath: try FileRules.canonical(path))
            return (url, try FileRules.child(name, in: url.deletingLastPathComponent().path))
        case let .delete(path):
            return (URL(fileURLWithPath: try FileRules.canonical(path)), nil)
        case let .importFile(source, directory):
            _ = try FileRules.canonical(source.path)
            return (source, try FileRules.child(source.lastPathComponent, in: directory))
        case let .addWallpaper(source, directory):
            try WallpaperPaths.validateDestination(directory)
            guard UUID(uuidString: source.lastPathComponent) != nil else { throw RunnerError(localized: "壁紙の追加先IDが不正です。") }
            return (source, try FileRules.child(source.lastPathComponent, in: directory))
        case .restoreBackup:
            throw RunnerError(localized: "復元先はManagerがバックアップ記録から決定します。")
        }
    }
}

struct FileWriteRequest: Identifiable, Sendable {
    let id: UUID
    let title: String
    let sourcePath: String?
    let destinationPath: String?
    var details: String? = nil
}

struct FileWriteReceipt: Sendable {
    let backupDirectory: URL
    let title: String
}
