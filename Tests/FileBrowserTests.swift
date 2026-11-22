import XCTest
@testable import RunnerCore

final class FileBrowserTests: XCTestCase {
    func testDateAndSizeSortWithDeterministicTies() async throws {
        let worker = FileListingWorker()
        let entries = [entry("b", size: 20, modified: Date(timeIntervalSince1970: 2)),
                       entry("a", size: 20, modified: Date(timeIntervalSince1970: 2)),
                       entry("c", size: 30, modified: Date(timeIntervalSince1970: 1)), entry("d")]
        let date = try await worker.apply(entries, search: "", options: .init(sortOrder: .modified))
        XCTAssertEqual(date.map(\.name), ["a", "b", "c", "d"])
        let size = try await worker.apply(entries, search: "", options: .init(sortOrder: .size))
        XCTAssertEqual(size.map(\.name), ["c", "a", "b", "d"])
        let reversed = try await worker.apply(entries, search: "", options: .init(sortOrder: .size, reversed: true))
        XCTAssertEqual(reversed.map(\.name), ["d", "b", "a", "c"])
    }

    func testComparatorIsStrictWithMissingDatesAndEquivalentNames() {
        let entries = [entry("a"), entry("b", modified: .distantPast), entry("A"), entry("a", directory: true)]
        for order in FileSortOrder.allCases {
            for reversed in [false, true] {
                let options = FileListingOptions(sortOrder: order, reversed: reversed)
                for lhs in entries {
                    XCTAssertFalse(options.precedes(lhs, lhs))
                    for rhs in entries where options.precedes(lhs, rhs) {
                        XCTAssertFalse(options.precedes(rhs, lhs))
                        for third in entries where options.precedes(rhs, third) {
                            XCTAssertTrue(options.precedes(lhs, third))
                        }
                    }
                }
            }
        }
    }

    func testCancelledListingAndArrangement() async throws {
        let service = FileAccessManager(), worker = FileListingWorker()
        let listing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.list(path: "/", showHidden: false)
        }
        do { _ = try await listing.value; XCTFail("Cancelled listing completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let arrangement = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.apply([], search: "", options: .init())
        }
        do { _ = try await arrangement.value; XCTFail("Cancelled arrangement completed") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPrefetchedMetadataPreservesLinksAndFileDetails() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("FileBrowserTests-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: root.appendingPathComponent("text.txt"))
        try files.createSymbolicLink(at: root.appendingPathComponent("folder-link"), withDestinationURL: folder)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("broken-link").path, withDestinationPath: root.appendingPathComponent("missing").path)
        let entries = try await FileAccessManager().list(path: root.path, showHidden: true)
        XCTAssertEqual(entries.count, 4)
        let text = try XCTUnwrap(entries.first { $0.name == "text.txt" })
        XCTAssertEqual(text.size, 5)
        XCTAssertNotNil(text.modified)
        XCTAssertFalse(text.isDirectory)
        for name in ["folder-link", "broken-link"] {
            let link = try XCTUnwrap(entries.first { $0.name == name })
            XCTAssertTrue(link.isSymbolicLink)
            XCTAssertFalse(link.isDirectory, "A link must not be treated as a discovered container")
        }
        let folderLink = try XCTUnwrap(entries.first { $0.name == "folder-link" })
        let resolved = try await FileAccessManager().resolveLink(folderLink)
        XCTAssertEqual(resolved.path, folder.resolvingSymlinksInPath().path)
        XCTAssertTrue(resolved.isDirectory)
        XCTAssertFalse(resolved.isSymbolicLink)
    }

    func testUnsupportedContainerPresetsAreHiddenOnIOS26() {
        XCTAssertFalse(PathPreset.availableContainers(majorVersion: 26).contains { $0.title == "App Groups" })
        XCTAssertFalse(PathPreset.availableContainers(majorVersion: 26).contains { $0.path.hasPrefix("/var/containers/") })
        let mobileGestalt = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/"
        XCTAssertFalse(PathPreset.availableLocations(majorVersion: 26).contains { $0.path == mobileGestalt })
        XCTAssertTrue(PathPreset.availableLocations(majorVersion: 27).contains { $0.path == mobileGestalt })
    }

    @MainActor
    func testOlderLoadCannotReplaceNewerLoadOrStopItsSpinner() async throws {
        let browser = FileBrowserModel()
        let firstGate = ListingGate(), secondGate = ListingGate()
        let firstStarted = expectation(description: "First request started")
        let secondStarted = expectation(description: "Second request started")
        let first = Task {
            await browser.reload(path: "/first", showHidden: false) { _, _ in
                firstStarted.fulfill()
                return try await firstGate.value()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        let second = Task {
            await browser.reload(path: "/second", showHidden: false) { _, _ in
                secondStarted.fulfill()
                return try await secondGate.value()
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        await firstGate.resolve(.success([entry("stale")]))
        await first.value
        XCTAssertTrue(browser.loading)
        XCTAssertTrue(browser.entries.isEmpty)
        await secondGate.resolve(.success([entry("current")]))
        await second.value
        await browser.updateVisible(search: "", options: .init())
        XCTAssertEqual(browser.visibleEntries.map(\.name), ["current"])
        XCTAssertFalse(browser.loading)
        XCTAssertFalse(browser.arranging)
    }

    @MainActor
    func testOlderFailureCannotReplaceNewerSuccess() async throws {
        let browser = FileBrowserModel(), gate = ListingGate()
        let started = expectation(description: "Old request started")
        let old = Task {
            await browser.reload(path: "/old", showHidden: false) { _, _ in
                started.fulfill()
                return try await gate.value()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let current = [entry("current")]
        await browser.reload(path: "/current", showHidden: false) { _, _ in current }
        await gate.resolve(.failure(RunnerError("Old failure")))
        await old.value
        await browser.updateVisible(search: "", options: .init())
        XCTAssertNil(browser.errorMessage)
        XCTAssertEqual(browser.visibleEntries.map(\.name), ["current"])
    }

    @MainActor
    func testDirectoryChangeClearsOldRowsBeforeNewLoadFinishes() async throws {
        let browser = FileBrowserModel(), gate = ListingGate()
        let oldEntries = [entry("old")]
        await browser.reload(path: "/old", showHidden: false) { _, _ in oldEntries }
        await browser.updateVisible(search: "", options: .init())
        XCTAssertEqual(browser.visibleEntries.count, 1)
        let started = expectation(description: "New folder is loading")
        let pending = Task {
            await browser.reload(path: "/new", showHidden: false) { _, _ in
                started.fulfill()
                return try await gate.value()
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertTrue(browser.visibleEntries.isEmpty)
        pending.cancel()
        await gate.resolve(.success([entry("cancelled")]))
        await pending.value
        await browser.updateVisible(search: "", options: .init())
        XCTAssertTrue(browser.visibleEntries.isEmpty)
        XCTAssertNil(browser.errorMessage)
        XCTAssertFalse(browser.loading)
        XCTAssertFalse(browser.arranging)
    }

    @MainActor
    func testSearchAndSortReuseLoadedSnapshot() async throws {
        let browser = FileBrowserModel(), counter = LoadCounter()
        let entries = [entry("report2", size: 2), entry("report10", size: 10), entry("photo")]
        await browser.reload(path: "/fixture", showHidden: false) { _, _ in
            await counter.increment()
            return entries
        }
        await browser.updateVisible(search: "report", options: .init())
        XCTAssertEqual(browser.visibleEntries.map(\.name), ["report2", "report10"])
        await browser.updateVisible(search: "report", options: .init(sortOrder: .size))
        XCTAssertEqual(browser.visibleEntries.map(\.name), ["report10", "report2"])
        let loads = await counter.count
        XCTAssertEqual(loads, 1)
    }

    private func entry(_ name: String, directory: Bool = false, size: Int64 = 0, modified: Date? = nil) -> FileEntry {
        FileEntry(path: "/fixture/\(name)", name: name, isDirectory: directory, isSymbolicLink: false, size: size, modified: modified)
    }
}

private actor ListingGate {
    private var continuation: CheckedContinuation<[FileEntry], Error>?
    private var result: Result<[FileEntry], Error>?

    func value() async throws -> [FileEntry] {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resolve(_ result: Result<[FileEntry], Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
