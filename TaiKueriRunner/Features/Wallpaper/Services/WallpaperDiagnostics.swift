import Foundation

// Local, bounded metadata only. Never includes wallpaper image bytes or plist contents.
struct WallpaperLibraryDiagnostics: Sendable {
    static let version = "wallpaper-gallery-20261115-r5-batter"
    let container: String
    let extensionsPath: String
    private(set) var counters: [String: Int] = [:]
    private(set) var events: [String] = []
    private(set) var omittedEvents = 0
    private var eventBytes = 0

    init(container: String, extensionsPath: String) {
        self.container = container
        self.extensionsPath = extensionsPath
    }

    mutating func count(_ key: String, by amount: Int = 1) {
        counters[key, default: 0] += amount
    }

    mutating func record(_ message: String) {
        let line = String(message.prefix(1024))
        let bytes = line.utf8.count
        guard events.count < 200, eventBytes + bytes <= 48 * 1024 else { omittedEvents += 1; return }
        events.append(line)
        eventBytes += bytes
    }

    mutating func listing(path: String, names: [String]) {
        let sample = names.prefix(8).map { String(reflecting: String($0.prefix(120))) }.joined(separator: ", ")
        record("LIST \(path)\n  count=\(names.count), names=[\(sample)]\(names.count > 8 ? " …" : "")")
    }

    var report: String {
        [
            L("診断版: \(String(describing: Self.version))"),
            L("OS: \(String(describing: ProcessInfo.processInfo.operatingSystemVersionString))"),
            L("PosterBoardコンテナ: \(String(describing: container))"),
            L("読み取り先: \(String(describing: extensionsPath))"),
            L("集計:\n") + counters.keys.sorted().map { "  \($0)=\(counters[$0]!)" }.joined(separator: "\n"),
            L("読み取り履歴（名前・パスのみ）:\n") + events.joined(separator: "\n"),
            L("上限による記録省略: \(String(describing: omittedEvents))件")
        ].joined(separator: "\n\n")
    }
}
