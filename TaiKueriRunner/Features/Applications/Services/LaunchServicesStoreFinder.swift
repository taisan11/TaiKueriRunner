// Recent-inode discovery adapted from WQFiles WQAccess.m (GPL-3.0-or-later).
import Foundation
#if SWIFT_PACKAGE
import NativeBridge
#endif

actor LaunchServicesStoreFinder {
    private let upperBound: @Sendable () -> UInt64
    private let candidates: @Sendable (UInt64, UInt64) -> [String]?
    private let now: @Sendable () -> TimeInterval

    init(upperBound: @escaping @Sendable () -> UInt64 = { TKLaunchServicesUpperBound() },
         candidates: @escaping @Sendable (UInt64, UInt64) -> [String]? = { TKLaunchServicesStoreCandidates($0, $1) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.upperBound = upperBound
        self.candidates = candidates
        self.now = now
    }

    // A time-limited search, never a claimed full-volume enumeration. Bad or
    // unreadable candidates are skipped instead of ending the search early.
    func find(accept: @Sendable (String) async throws -> ApplicationCatalogSnapshot?,
              progress: @Sendable (String) async -> Void) async throws -> ApplicationCatalogSnapshot {
        try Task.checkCancellation()
        let bound = upperBound()
        guard bound > 0 else { throw RunnerError(localized: "DB探索用のinodeを取得できません。データボリュームへのアクセスを確認して再検索してください。") }
        let started = now(), maximumIDs: UInt64 = 2_000_000
        var last = bound, checked: UInt64 = 0, attempts = 0
        var seen = Set<String>()
        while last > 0, checked < maximumIDs, now() - started < 20 {
            try Task.checkCancellation()
            let count = min(2048, last, maximumIDs - checked)
            let first = last - count + 1
            guard let paths = autoreleasepool(invoking: { candidates(first, last) }) else {
                throw RunnerError(localized: "データボリュームのDB探索を開始できません。")
            }
            for path in paths where LaunchServicesPaths.daemonContainer(forStore: path) != nil && seen.insert(path).inserted {
                try Task.checkCancellation()
                guard now() - started < 20, attempts < 32 else { break }
                attempts += 1
                await progress(L("LaunchServices DBを検証中…"))
                if let result = try await accept(path) { return result }
            }
            checked += count
            if checked == count || checked.isMultiple(of: 16_384) {
                await progress(L("新しいinodeからDBを探索中… \(String(describing: checked.formatted()))件確認"))
            }
            if first == 1 || attempts >= 32 { break }
            last = first - 1
            await Task.yield()
        }
        try Task.checkCancellation()
        throw RunnerError(localized: "制限時間・探索範囲内で読み取れるLaunchServices DBを自動選択できませんでした。全ファイルの探索は行っていません。App Groupとアクセス権を確認して再検索してください。")
    }
}
