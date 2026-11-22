import XCTest
@testable import RunnerCore

final class WallpaperAsyncTests: XCTestCase {
    @MainActor
    func testPartialGridIsUsableBeforeCompletionAndCancelKeepsItWithoutAcceptingLateProgress() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WallpaperLibraryModel(), gate = AsyncWallpaperGate()
        let partial = try load(root, count: 1), late = try load(root, count: 2)
        let ready = expectation(description: "Partial grid published")
        let task = Task {
            await model.loadProgressively { publish in
                await publish(partial)
                ready.fulfill()
                await gate.wait()
                await publish(late)
                return late
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(model.loading)
        XCTAssertEqual(model.result?.snapshot.items.count, 1)
        XCTAssertEqual(model.processedCount, 1)
        XCTAssertFalse(model.hasCompleteSnapshot)
        // The MainActor can process another UI action while loading is suspended.
        var uiActionRan = false
        await Task { @MainActor in uiActionRan = true }.value
        XCTAssertTrue(uiActionRan)
        model.cancel(clearResult: false)
        await gate.open()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.result?.snapshot.items.count, 1)
        XCTAssertEqual(model.revision, 0)
        XCTAssertFalse(model.hasCompleteSnapshot)
    }

    @MainActor
    func testRefreshPreservesPreviousGridUntilNewSnapshotCompletes() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WallpaperLibraryModel(), gate = AsyncWallpaperGate()
        let original = try load(root, count: 3), partial = try load(root, count: 1), final = try load(root, count: 5)
        await model.load { original }
        let ready = expectation(description: "Refresh progress published")
        let task = Task {
            await model.loadProgressively { publish in
                await publish(partial)
                ready.fulfill()
                await gate.wait()
                return final
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(model.loading)
        XCTAssertTrue(model.hasCompleteSnapshot)
        XCTAssertEqual(model.result?.snapshot.items.count, 3)
        XCTAssertEqual(model.processedCount, 1)
        await gate.open()
        await task.value
        XCTAssertEqual(model.result?.snapshot.items.count, 5)
        XCTAssertEqual(model.revision, 2)
        XCTAssertFalse(model.loading)
    }

    @MainActor
    func testNewRequestCancelsUnderlyingTaskAndRejectsItsLateEvents() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WallpaperLibraryModel(), gate = AsyncWallpaperGate()
        let stale = try load(root, count: 1), current = try load(root, count: 4)
        let started = expectation(description: "Old loader started")
        let cancelled = expectation(description: "Old loader received cancellation")
        let old = Task {
            await model.loadProgressively { publish in
                await withTaskCancellationHandler {
                    started.fulfill()
                    await gate.wait()
                    await publish(stale)
                } onCancel: {
                    cancelled.fulfill()
                }
                return stale
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.load { current }
        await fulfillment(of: [cancelled], timeout: 2)
        await gate.open()
        await old.value
        XCTAssertEqual(model.result?.snapshot.items.count, 4)
        XCTAssertEqual(model.processedCount, 4)
        XCTAssertEqual(model.revision, 1)
        XCTAssertFalse(model.loading)
    }

    @MainActor
    func testAlreadyCancelledCallerCannotReplaceAnActiveScan() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WallpaperLibraryModel(), gate = AsyncWallpaperGate()
        let partial = try load(root, count: 1), final = try load(root, count: 2)
        let ready = expectation(description: "Current scan is running")
        let current = Task {
            await model.loadProgressively { publish in
                await publish(partial)
                ready.fulfill()
                await gate.wait()
                return final
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        var staleLoaderRan = false
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load { staleLoaderRan = true; return partial }
        }.value
        XCTAssertFalse(staleLoaderRan)
        XCTAssertTrue(model.loading)
        await gate.open()
        await current.value
        XCTAssertEqual(model.result?.snapshot.items.count, 2)
        XCTAssertEqual(model.revision, 1)
    }

    @MainActor
    func testOtherFileReadsAndWritesCompleteWhileWallpaperScanIsSuspendedBetweenBatches() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let virtual = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let provider = "com.apple.WallpaperKit.CollectionsPoster"
        for _ in 0..<2 {
            let wallpaper = root.appendingPathComponent(WallpaperPaths.store + "/Extensions/" + provider + "/descriptors/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: wallpaper.appendingPathComponent("versions/1/contents"), withIntermediateDirectories: true)
            try Data("7420".utf8).write(to: wallpaper.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"))
        }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let access = AsyncWallpaperAccess(root: root, virtual: virtual, manager: manager)
        let worker = WallpaperLibraryWorker(files: access)
        let gate = AsyncWallpaperGate()
        let ready = expectation(description: "First wallpaper loaded")
        var scanCompleted = false
        let scanning = Task {
            let result = try await worker.load(container: virtual) { partial in
                if partial.items.count == 1 {
                    ready.fulfill()
                    await gate.wait()
                }
            }
            scanCompleted = true
            return result
        }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertFalse(scanCompleted)
        let text = root.appendingPathComponent("other-tab.txt")
        try Data("before".utf8).write(to: text)
        let completed = expectation(description: "Other tab I/O completed before scan resumes")
        let otherTab = Task {
            let original = try await manager.readText(path: text.path)
            let request = try await manager.prepareWrite(.saveText(path: text.path, text: "after", original: original))
            _ = try await manager.commitWrite(request, userConsented: true)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(scanCompleted)
        await gate.open()
        try await otherTab.value
        let snapshot = try await scanning.value
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.path.hasPrefix(virtual + "/") })
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "after")
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    @MainActor
    func testCancellingScanStopsBeforeNextFileBatch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let virtual = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let provider = "com.apple.WallpaperKit.CollectionsPoster"
        for _ in 0..<2 {
            let wallpaper = root.appendingPathComponent(WallpaperPaths.store + "/Extensions/" + provider + "/descriptors/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: wallpaper.appendingPathComponent("versions/1/contents"), withIntermediateDirectories: true)
            try Data("7420".utf8).write(to: wallpaper.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"))
        }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let access = AsyncWallpaperAccess(root: root, virtual: virtual, manager: manager)
        let gate = AsyncWallpaperGate()
        let ready = expectation(description: "Scan reached a cancellable boundary")
        let task = Task {
            try await WallpaperLibraryWorker(files: access).load(container: virtual) { partial in
                if partial.items.count == 1 { ready.fulfill(); await gate.wait() }
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        let before = await access.calls
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled scan completed") } catch is CancellationError {}
        let after = await access.calls
        XCTAssertEqual(after, before)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperAsyncTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func load(_ root: URL, count: Int) throws -> WallpaperLibraryLoad {
        let snapshot = try FileBackupStore.Snapshot(path: root.path)
        let items = (0..<count).map { index in
            InstalledWallpaper(path: root.path + "/\(index)", provider: "com.apple.WallpaperKit.CollectionsPoster",
                               location: .descriptors, title: "Wallpaper \(index)", identifier: String(index), previewPath: nil,
                               snapshot: snapshot, installationBackupID: nil)
        }
        return WallpaperLibraryLoad(container: root.path, storePath: nil,
            snapshot: WallpaperLibrarySnapshot(items: items, unreadableCount: 0, latestChange: nil, refreshRequired: false))
    }
}

private actor AsyncWallpaperGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AsyncWallpaperAccess: WallpaperLibraryAccess {
    let root: URL
    let virtual: String
    let manager: FileAccessManager
    private(set) var calls = 0
    init(root: URL, virtual: String, manager: FileAccessManager) {
        self.root = root; self.virtual = virtual; self.manager = manager
    }

    func readWallpaperDirectory(path: String, container: String) async throws -> [FileEntry] {
        calls += 1
        try Task.checkCancellation()
        let entries = try await manager.list(path: backing(path), showHidden: true)
        return try entries.map { try WallpaperPaths.listedEntry($0, in: path) }
    }
    func readWallpaperAttributes(path: String, container: String) throws -> FileBackupStore.Snapshot {
        calls += 1
        try Task.checkCancellation()
        return try FileBackupStore.Snapshot(path: backing(path))
    }
    func readWallpaperMetadata(path: String, container: String, maximumBytes: Int) async throws -> Data {
        calls += 1
        try Task.checkCancellation()
        return Data(try await manager.readText(path: backing(path)).utf8)
    }
    func wallpaperBackupIDs() async throws -> [String] { try await manager.wallpaperBackupIDs() }
    func wallpaperBackupRecord(id: String) async throws -> FileBackupRecord { try await manager.wallpaperBackupRecord(id: id) }

    private func backing(_ path: String) throws -> String {
        let normalized = try WallpaperPaths.normalized(path)
        guard normalized == virtual || normalized.hasPrefix(virtual + "/") else { throw RunnerError("Outside test fixture") }
        return root.path + normalized.dropFirst(virtual.count)
    }
}
