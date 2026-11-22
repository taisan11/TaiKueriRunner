import Foundation
#if SWIFT_PACKAGE
import NativeBridge
#endif

struct RunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
    init(localized key: String.LocalizationValue) { self.message = L(key) }
}

enum RuntimeSupport {
    static let allowedVersionRange = "26.0–26.7.2 / 27.0–27.2.1"

    static func isReportedSupported(_ version: OperatingSystemVersion) -> Bool {
        if version.majorVersion == 26 {
            return version.minorVersion < 7 || (version.minorVersion == 7 && version.patchVersion <= 2)
        }
        // 27.2.1 is enabled on the user's device report; not locally verified.
        return version.majorVersion == 27 && (version.minorVersion < 2 || (version.minorVersion == 2 && version.patchVersion <= 1))
    }

    static let entitledGroupIDs: [String] = runner_app_group_identifiers()
    static let appGroup = AppGroupSelection.resolve(
        entitledGroups: entitledGroupIDs,
        containerURL: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    )

    static var groupID: String { appGroup?.identifier ?? "" }
}

struct AppGroupSelection: Sendable {
    let identifier: String
    let containerURL: URL

    static func resolve(entitledGroups: [String], containerURL: (String) -> URL?) -> AppGroupSelection? {
        // The Apple ID signer supplies the IDs. No manual ID or account-tier
        // configuration is needed; use the first accessible signed group.
        let groups = entitledGroups.filter { !$0.isEmpty && !$0.contains("*") && !$0.contains("$(") }
        var visited = Set<String>()
        for group in groups where visited.insert(group).inserted {
            if let url = containerURL(group) {
                return .init(identifier: group, containerURL: url)
            }
        }
        return nil
    }
}

struct AccessGrant: Identifiable, Sendable {
    let path: String
    let handle: Int64
    let created: Date
    var id: String { path }
}

struct FileEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date?
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var icon: String { isSymbolicLink ? "link" : isDirectory ? "folder.fill" : "doc" }
}

enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name, modified, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return L("名前（A → Z）")
        case .modified: return L("更新日（新しい順）")
        case .size: return L("サイズ（大きい順）")
        }
    }
}

struct FileListingOptions: Equatable, Sendable {
    var sortOrder: FileSortOrder = .name
    var reversed = false
    var foldersFirst = true

    func precedes(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if foldersFirst && lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let comparison: ComparisonResult
        switch sortOrder {
        case .modified where (lhs.modified ?? .distantPast) != (rhs.modified ?? .distantPast):
            comparison = (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast) ? .orderedAscending : .orderedDescending
        case .size where lhs.size != rhs.size:
            comparison = lhs.size > rhs.size ? .orderedAscending : .orderedDescending
        default:
            let names = lhs.name.localizedStandardCompare(rhs.name)
            // A path tie-breaker keeps ordering deterministic for equivalent names.
            comparison = names == .orderedSame ? lhs.path.compare(rhs.path) : names
        }
        return reversed ? comparison == .orderedDescending : comparison == .orderedAscending
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let isError: Bool
}

enum FileRules {
    static func ancestorPaths(of path: String) -> [String] {
        guard var current = try? canonical(path) else { return [] }
        var ancestors: [String] = []
        while current != "/" {
            current = (current as NSString).deletingLastPathComponent
            ancestors.append(current)
        }
        return ancestors
    }

    static func canonical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw RunnerError(localized: "絶対パス（/ で始まるパス）を指定してください。")
        }
        return (path as NSString).standardizingPath
    }

    static func child(_ name: String, in directory: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw RunnerError(localized: "名前は空にできません。/、.、.. は使用できません。")
        }
        return URL(fileURLWithPath: try canonical(directory)).appendingPathComponent(name)
    }

}

struct PathPreset: Identifiable, Sendable {
    let title: String
    let path: String
    let note: String
    var minimumMajorVersion = 26
    var id: String { path }

    static func availableContainers(majorVersion: Int) -> [PathPreset] {
        containers.filter { majorVersion >= $0.minimumMajorVersion }
    }

    static func availableLocations(majorVersion: Int,
                                   documents: String = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path,
                                   home: String = NSHomeDirectory()) -> [PathPreset] {
        [.init(title: L("Documents"), path: documents, note: L("このアプリの書類")),
         .init(title: L("アプリのホーム"), path: home, note: L("このアプリのコンテナ"))]
        + availableContainers(majorVersion: majorVersion)
    }

    static let containers: [PathPreset] = [
        .init(title: L("Applications"), path: "/var/mobile/Containers/Data/Application", note: L("26系は個別UUIDの指定、またはパス列挙が必要")),
        .init(title: L("App Groups"), path: "/var/mobile/Containers/Shared/AppGroup", note: L("親ディレクトリへのアクセスは27系のみ"), minimumMajorVersion: 27),
        .init(title: L("Internal Daemons"), path: "/var/mobile/Containers/Data/InternalDaemon", note: L("個別コンテナを指定")),
        .init(title: L("Plug-ins"), path: "/var/mobile/Containers/Data/PluginKitPlugin", note: L("個別コンテナを指定")),
        .init(title: L("System Data"), path: "/var/containers/Data/System", note: L("27系のみ"), minimumMajorVersion: 27),
        .init(title: L("System Groups"), path: "/var/containers/Shared/SystemGroup", note: L("27系・個別コンテナを指定"), minimumMajorVersion: 27),
        .init(title: L("MobileGestalt Cache"), path: "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/", note: L("27系・System Group内のキャッシュ（アクセス可否はOS次第）"), minimumMajorVersion: 27)
    ]
}
