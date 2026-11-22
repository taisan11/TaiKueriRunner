import Foundation

enum ApplicationKind: String, CaseIterable, Identifiable, Sendable {
    case application, appExtension
    var id: String { rawValue }
    var title: String { self == .application ? L("アプリ") : L("拡張機能") }
}

struct CatalogApplication: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let kind: ApplicationKind
    let containerPaths: [String]
    let bundlePath: String?
    var id: String { "\(kind.rawValue):\(bundleID)" }
    var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

enum ApplicationSearchScope: String, CaseIterable, Identifiable, Sendable {
    case name, bundleID, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: L("アプリ名")
        case .bundleID: L("Bundle ID")
        case .all: L("両方")
        }
    }

    func matches(_ application: CatalogApplication, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return (self != .bundleID && application.name.localizedStandardContains(query)) ||
               (self != .name && application.bundleID.localizedStandardContains(query))
    }
}

struct ParsedApplicationCatalog: Equatable, Sendable {
    let layout: String
    let applications: [CatalogApplication]
    let sharedGroupPaths: [String]
    let ambiguousContainerCount: Int
    var sharedGroupIdentifiers: [String: Set<String>] = [:]
}

struct ApplicationCatalogSnapshot: Sendable {
    let catalog: ParsedApplicationCatalog
    let sourcePath: String
    let loadedAt: Date
}

enum LaunchServicesPaths {
    static let daemonRoot = "/var/mobile/Containers/Data/InternalDaemon"
    static let applicationRoot = "/var/mobile/Containers/Data/Application"
    static let extensionRoot = "/var/mobile/Containers/Data/PluginKitPlugin"
    static let groupRoot = "/var/mobile/Containers/Shared/AppGroup"

    // Do not turn arbitrary paths from a database into access requests.
    static func container(_ raw: String, root: String) -> String? {
        var path = raw.hasPrefix("/private/var/") ? String(raw.dropFirst(8)) : raw
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix(root + "/") else { return nil }
        let component = String(path.dropFirst(root.count + 1))
        guard component.count == 36, let uuid = UUID(uuidString: component) else { return nil }
        return root + "/" + uuid.uuidString
    }

    static func dataContainer(_ raw: String) -> String? {
        container(raw, root: applicationRoot) ?? container(raw, root: extensionRoot)
    }

    static func daemonContainer(forStore raw: String) -> String? {
        let path = raw.hasPrefix("/private/var/") ? String(raw.dropFirst(8)) : raw
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard name.hasPrefix("com.apple.LaunchServices-"), name.hasSuffix(".csstore"),
              name.count > 33, raw.rangeOfCharacter(from: .controlCharacters) == nil,
              path == (path as NSString).standardizingPath,
              url.deletingLastPathComponent().lastPathComponent == "Caches",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Library" else { return nil }
        return container(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path, root: daemonRoot)
    }

    static func accessTargets(forStore raw: String) -> [String]? {
        guard daemonContainer(forStore: raw) != nil else { return nil }
        let path = raw.hasPrefix("/private/var/") ? String(raw.dropFirst(8)) : raw
        return [URL(fileURLWithPath: path).deletingLastPathComponent().path, path]
    }

    static func bundlePath(_ raw: String) -> String? {
        var path = raw.hasPrefix("/private/var/") ? String(raw.dropFirst(8)) : raw
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix(".app"), path == (path as NSString).standardizingPath, !path.contains("\0") else { return nil }
        if path.hasPrefix("/Applications/"), URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Applications" { return path }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return container(parent, root: "/var/containers/Bundle/Application") != nil ? path : nil
    }
}
