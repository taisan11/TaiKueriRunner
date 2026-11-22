import XCTest
@testable import RunnerCore

final class WallpaperCacheTests: XCTestCase {
    @MainActor
    func testCompleteSnapshotIsReusedAcrossNavigationUntilThreeMinuteExpiry() async {
        var time = Date(timeIntervalSince1970: 1000)
        let model = WallpaperLibraryModel(now: { time })
        let result = empty()
        var calls = 0
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        model.cancel(clearResult: false)
        time.addTimeInterval(179)
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.hasCompleteSnapshot)
        XCTAssertFalse(model.loading)
        time.addTimeInterval(1)
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.revision, 2)
    }

    @MainActor
    func testManualRefreshFileChangesAndExplicitInvalidationBypassCache() async {
        let model = WallpaperLibraryModel()
        let result = empty()
        var calls = 0
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        await model.refresh(fileRevision: 1, force: true) { _ in calls += 1; return result }
        await model.refresh(fileRevision: 2) { _ in calls += 1; return result }
        model.invalidateCache()
        XCTAssertNotNil(model.result)
        await model.refresh(fileRevision: 2) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 4)
    }

    @MainActor
    func testPartialAndFailedResultsAreNeverReusableCacheEntries() async {
        let model = WallpaperLibraryModel()
        let result = empty()
        var calls = 0
        await model.refresh(fileRevision: 1) { publish in
            calls += 1
            await publish(result)
            throw CancellationError()
        }
        XCTAssertNotNil(model.result)
        XCTAssertFalse(model.hasCompleteSnapshot)
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 2)
        await model.refresh(fileRevision: 1, force: true) { _ in calls += 1; throw RunnerError("read failed") }
        XCTAssertNil(model.result)
        XCTAssertEqual(model.error, "read failed")
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 4)
    }

    @MainActor
    func testInvalidationDuringScanCannotBeUndoneByLateCompletion() async {
        let model = WallpaperLibraryModel(), gate = CacheGate()
        let result = empty()
        let started = expectation(description: "Scan started")
        let loading = Task {
            await model.refresh(fileRevision: 1) { _ in
                started.fulfill()
                await gate.wait()
                return result
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.invalidateCache()
        await gate.open()
        await loading.value
        var rescanned = false
        await model.refresh(fileRevision: 1) { _ in rescanned = true; return result }
        XCTAssertTrue(rescanned)
    }

    @MainActor
    func testCancelledCallerCannotUseOrReplaceNewerScan() async {
        let model = WallpaperLibraryModel()
        let result = empty()
        await model.refresh(fileRevision: 1) { _ in result }
        var invoked = false
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refresh(fileRevision: 2, force: true) { _ in invoked = true; return result }
        }.value
        XCTAssertFalse(invoked)
        XCTAssertEqual(model.revision, 1)
        await model.refresh(fileRevision: 1) { _ in invoked = true; return result }
        XCTAssertFalse(invoked)
    }

    @MainActor
    func testClearingResultsAndClockMovingBackwardCannotReuseOldCache() async {
        var time = Date(timeIntervalSince1970: 1000)
        let model = WallpaperLibraryModel(now: { time })
        let result = empty()
        var calls = 0
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        time.addTimeInterval(-1)
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 2)
        model.cancel()
        await model.refresh(fileRevision: 1) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 3)
    }

    func testPhotosAndVideosAreHiddenByDefaultWithoutDroppingCachedItems() throws {
        let root = FileManager.default.temporaryDirectory
        let snapshot = try FileBackupStore.Snapshot(path: root.path)
        let providers = ["com.apple.WallpaperKit.CollectionsPoster", "com.apple.MercuryPoster",
                         "com.apple.PhotosUIPrivate.PhotosPosterProvider", "com.apple.WallpaperKit.WeatherPoster"]
        let items = providers.map {
            InstalledWallpaper(path: root.path + "/" + $0, provider: $0, location: .descriptors,
                               title: $0, identifier: $0, previewPath: nil, snapshot: snapshot, installationBackupID: nil)
        }
        XCTAssertEqual(items.filter { $0.isVisible() }.count, 3)
        XCTAssertEqual(items.filter { $0.isVisible(showPhotosAndVideos: true) }.count, 4)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items[2].isPhotoOrVideo)
        XCTAssertFalse(items[0].isPhotoOrVideo)
    }

    private func empty() -> WallpaperLibraryLoad {
        WallpaperLibraryLoad(container: "test", storePath: nil,
            snapshot: WallpaperLibrarySnapshot(items: [], unreadableCount: 0, latestChange: nil, refreshRequired: false))
    }
}

private actor CacheGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
