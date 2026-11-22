import XCTest
@testable import RunnerCore

final class ApplicationReadCacheTests: XCTestCase {
    private let store = LaunchServicesPaths.daemonRoot + "/11111111-1111-4111-8111-111111111111/Library/Caches/com.apple.LaunchServices-v2.csstore"
    private let path = AppGroupPaths.root + "/22222222-2222-4222-8222-222222222222"

    func testCacheReusesUntilInvalidatedAndRejectsLateReplacement() {
        var cache = SessionReadCache<String, String>()
        let token = cache.invalidate()
        cache.store("value", for: "key", token: token)
        XCTAssertEqual(cache.value(for: "key"), "value")
        XCTAssertNil(cache.value(for: "other"))
        let next = cache.invalidate()
        cache.store("new", for: "key", token: next)
        cache.store("stale", for: "key", token: token)
        XCTAssertEqual(cache.value(for: "key"), "new")
    }

    func testInvalidationAndNewerRequestPreventLateCacheReplacement() {
        var cache = SessionReadCache<Int, String>()
        let old = cache.invalidate(), current = cache.invalidate()
        cache.store("current", for: 2, token: current)
        cache.store("stale", for: 1, token: old)
        XCTAssertEqual(cache.value(for: 2), "current")
        cache.invalidate()
        cache.store("late", for: 2, token: current)
        XCTAssertNil(cache.value(for: 2))
    }

    func testCatalogIsReusedForTheSessionUntilGroupChangeOrExplicitRefresh() async throws {
        let files = CatalogCacheAccess()
        let service = service(files)
        let first = try await load(service)
        let second = try await load(service)
        XCTAssertEqual(first.catalog, second.catalog)
        var reads = await files.reads
        XCTAssertEqual(reads, 1)

        // Returning to the screen does not read again.
        _ = try await load(service)
        reads = await files.reads
        XCTAssertEqual(reads, 1)

        // A different signing group and an explicit refresh are misses.
        _ = try await service.load(cachedPath: store, group: "other.group", freshSearch: false, progress: { _ in })
        _ = try await service.load(cachedPath: store, group: "other.group", freshSearch: false,
                                   forceRefresh: true, progress: { _ in })
        reads = await files.reads
        XCTAssertEqual(reads, 3)
    }

    func testFreshSearchAndFailedForcedReadDoNotFallBackToOldCatalog() async throws {
        let files = CatalogCacheAccess(), service = service(CatalogCacheAccess())
        _ = try await load(service)
        do {
            _ = try await service.load(cachedPath: store, group: "group.test", freshSearch: true, progress: { _ in })
            XCTFail("Fresh search reused cached catalog instead of searching")
        } catch {}
        let failing = self.service(files)
        _ = try await load(failing)
        await files.setFailure(true)
        do { _ = try await load(failing, force: true); XCTFail("Forced failure reused old catalog") } catch {}
        await files.setFailure(false)
        _ = try await load(failing)
        let reads = await files.reads
        XCTAssertEqual(reads, 3)
    }

    func testCancelledCatalogDoesNotEnterCache() async throws {
        let files = CatalogCacheAccess(), service = service(files)
        await files.cancelRead()
        do { _ = try await load(service); XCTFail("Cancellation ignored") }
        catch is CancellationError {}
        _ = try await load(service)
        let reads = await files.reads
        XCTAssertEqual(reads, 2)
    }

    @MainActor
    func testOlderCatalogReadCannotReplaceARefreshedSnapshot() async throws {
        let gate = ReadCacheGate(), started = expectation(description: "Old DB read started")
        let files = CatalogCacheAccess(gate: gate, onFirstRead: { started.fulfill() })
        let service = self.service(files), path = store
        let old = Task {
            try await service.load(cachedPath: path, group: "group.test", freshSearch: false, progress: { _ in })
        }
        await fulfillment(of: [started], timeout: 2)
        _ = try await service.load(cachedPath: path, group: "group.test", freshSearch: false,
                                   forceRefresh: true, progress: { _ in })
        await gate.open()
        _ = try await old.value
        _ = try await service.load(cachedPath: path, group: "group.test", freshSearch: false,
                                   progress: { _ in })
        let reads = await files.reads
        XCTAssertEqual(reads, 2)
    }

    func testGroupCacheReusesEnumerationAndMetadataUntilRefresh() async throws {
        let files = GroupCacheAccess()
        let scanner = AppGroupScanner(files: files)
        let catalog = catalog()
        _ = try await scanner.scan(knownPaths: [path], catalog: catalog)
        _ = try await scanner.scan(knownPaths: ["/private" + path], catalog: catalog, progress: { _ in
            XCTFail("A cached result should not publish partial scanning progress")
        })
        var calls = await files.counts
        XCTAssertEqual(calls, [1, 1])
        _ = try await scanner.scan(knownPaths: [path], catalog: catalog, forceRefresh: true)
        _ = try await scanner.scan(knownPaths: [path], catalog: catalog)
        calls = await files.counts
        XCTAssertEqual(calls, [2, 2])
    }

    func testGroupCacheSeparatesCatalogContentsAndDBReadGeneration() async throws {
        let files = GroupCacheAccess(), scanner = AppGroupScanner(files: files)
        let first = catalog()
        _ = try await scanner.scan(knownPaths: [path], catalog: first, catalogLoadedAt: Date(timeIntervalSince1970: 1))
        _ = try await scanner.scan(knownPaths: [path], catalog: first, catalogLoadedAt: Date(timeIntervalSince1970: 2))
        var changed = first
        changed.sharedGroupIdentifiers = [path: ["group.changed"]]
        _ = try await scanner.scan(knownPaths: [path], catalog: changed, catalogLoadedAt: Date(timeIntervalSince1970: 2))
        let calls = await files.counts
        XCTAssertEqual(calls, [3, 3])
    }

    func testDBFailureIsRetriedButInaccessibleEmptyResultIsReused() async throws {
        let files = GroupCacheAccess(), scanner = AppGroupScanner(files: files)
        let input = catalog()
        _ = try await scanner.scan(knownPaths: [path], catalog: input)
        _ = try await scanner.scan(knownPaths: [path], catalog: input, catalogIssue: "DB unavailable")
        _ = try await scanner.scan(knownPaths: [path], catalog: input)
        var calls = await files.counts
        XCTAssertEqual(calls, [3, 3]) // The DB-failure scan is never cached.
        await files.setDenyRoot()
        await scanner.invalidateCache()
        _ = try await scanner.scan(knownPaths: [])
        _ = try await scanner.scan(knownPaths: [])
        calls = await files.counts
        XCTAssertEqual(calls[0], 4) // An inaccessible empty result is reused too.
        let warned = try await scanner.scan(knownPaths: [path], catalog: input)
        let reused = try await scanner.scan(knownPaths: [path], catalog: input)
        XCTAssertNotNil(warned.rootIssue)
        XCTAssertEqual(reused.rootIssue, warned.rootIssue)
        calls = await files.counts
        XCTAssertEqual(calls, [5, 4])
    }

    @MainActor
    func testCancelledPartialGroupScanIsNotCachedAndLateCompletionCannotReplaceNewCache() async throws {
        let files = GroupCacheAccess(), scanner = AppGroupScanner(files: files), gate = ReadCacheGate()
        let started = expectation(description: "First partial result")
        let path = self.path, input = catalog()
        let old = Task {
            try await scanner.scan(knownPaths: [path], catalog: input) { partial in
                if partial.scannedCount == 1 && partial.phase == "共有フォルダを確認中…" {
                    started.fulfill()
                    await gate.wait()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        _ = try await scanner.scan(knownPaths: [path], catalog: input, forceRefresh: true)
        await gate.open()
        do { _ = try await old.value; XCTFail("Partial scan completed") } catch is CancellationError {}
        _ = try await scanner.scan(knownPaths: [path], catalog: input)
        let calls = await files.counts
        XCTAssertEqual(calls, [2, 2])
    }

    @MainActor
    func testOlderSuccessfulReadCannotReplaceNewerCache() async throws {
        let files = GroupCacheAccess(), scanner = AppGroupScanner(files: files), gate = ReadCacheGate()
        let started = expectation(description: "Old read suspended")
        let path = self.path, input = catalog()
        let old = Task {
            try await scanner.scan(knownPaths: [path], catalog: input) { partial in
                if partial.scannedCount == 1 && partial.phase == "共有フォルダを確認中…" {
                    started.fulfill()
                    await gate.wait()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        var changed = input
        changed.sharedGroupIdentifiers = [path: ["group.new"]]
        _ = try await scanner.scan(knownPaths: [path], catalog: changed, forceRefresh: true)
        await gate.open()
        _ = try await old.value
        _ = try await scanner.scan(knownPaths: [path], catalog: changed)
        let calls = await files.counts
        XCTAssertEqual(calls, [2, 2])
    }

    private func catalog() -> ParsedApplicationCatalog { fixtureCatalog() }
    private func service(_ files: CatalogCacheAccess) -> ApplicationCatalogService {
        ApplicationCatalogService(files: files,
            finder: LaunchServicesStoreFinder(upperBound: { 0 }, candidates: { _, _ in [] }))
    }
    private func load(_ service: ApplicationCatalogService, force: Bool = false) async throws -> ApplicationCatalogSnapshot {
        try await service.load(cachedPath: store, group: "group.test", freshSearch: false,
                               forceRefresh: force, progress: { _ in })
    }
}

private func fixtureCatalog() -> ParsedApplicationCatalog {
    let app = CatalogApplication(bundleID: "com.example.app", name: "Fixture", kind: .application, containerPaths: [], bundlePath: nil)
    return ParsedApplicationCatalog(layout: "fixture", applications: [app], sharedGroupPaths: [], ambiguousContainerCount: 0)
}

private actor CatalogCacheAccess: ApplicationCatalogAccess {
    private(set) var reads = 0
    private var fail = false, cancel = false
    private let gate: ReadCacheGate?
    private let onFirstRead: @Sendable () -> Void
    init(gate: ReadCacheGate? = nil, onFirstRead: @escaping @Sendable () -> Void = {}) {
        self.gate = gate
        self.onFirstRead = onFirstRead
    }
    func setFailure(_ value: Bool) { fail = value }
    func cancelRead() { cancel = true }
    func readLaunchServicesCatalog(path: String, group: String) async throws -> ParsedApplicationCatalog {
        reads += 1
        if reads == 1, let gate { onFirstRead(); await gate.wait() }
        if cancel { cancel = false; throw CancellationError() }
        if fail { throw RunnerError("DB read failed") }
        return fixtureCatalog()
    }
}

private actor GroupCacheAccess: AppGroupAccess {
    private var root = 0, metadata = 0, denyRoot = false
    var counts: [Int] { [root, metadata] }
    func setDenyRoot() { denyRoot = true }
    func appGroupCandidateNames() throws -> [String] {
        root += 1
        if denyRoot { throw POSIXError(.EACCES) }
        return []
    }
    func inspectAppGroup(path: String) -> AppGroupContainer? {
        metadata += 1
        return AppGroupContainer(path: path, groupID: nil, canOpen: true, issues: [])
    }
}

private actor ReadCacheGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
