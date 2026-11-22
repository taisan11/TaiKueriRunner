import XCTest
import CoreGraphics
import ImageIO
@testable import RunnerCore

final class WallpaperLibraryTests: XCTestCase {
    private let provider = "com.apple.WallpaperKit.CollectionsPoster"

    func testLibraryReadsDeviceFoldersInsteadOfShowingOnlyImportHistory() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = try wallpaper(root, provider: provider, kind: "descriptors", asset: "9183.Nebula-810w-1080h@2x~ipad.wallpaper")
        let system = try wallpaper(root, provider: "com.apple.ClockPoster.ClockPosterExtension", kind: "descriptors", identifier: "digital")
        let saved = try wallpaper(root, provider: provider, kind: "configurations", identifier: "7420")
        let old = managed.appendingPathComponent("versions/1/contents/Wrong.wallpaper")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data([1]).write(to: old.appendingPathComponent("preview.png"))
        let scratch = managed.appendingPathComponent("versions/10/scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        try Data([1]).write(to: scratch.appendingPathComponent("preview.png"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("versions/10/contents/link"), withDestinationURL: outside)
        let extensions = root.appendingPathComponent(WallpaperPaths.store + "/Extensions")
        try FileManager.default.createSymbolicLink(at: extensions.appendingPathComponent("com.apple.Linked"), withDestinationURL: outside)
        let metadata = WallpaperBackupMetadata(changeID: UUID(), title: "My Nebula", package: "Nebula.tendie", isRefresh: false)
        let installed = try record(path: managed, kind: "addWallpaper", date: 100, metadata: metadata)
        let ghost = try record(path: root.appendingPathComponent("not-installed"), kind: "addWallpaper", date: 90,
                               snapshot: FileBackupStore.Snapshot(path: managed.path))
        var accessed: [String] = []
        let reader = reader { accessed.append($0) }
        let snapshot = try await reader.load(container: root.path, backups: [installed, ghost])
        XCTAssertEqual(snapshot.items.count, 3)
        let item = try XCTUnwrap(snapshot.items.first { $0.path == managed.path })
        XCTAssertTrue(item.isManaged)
        XCTAssertEqual(item.title, "My Nebula")
        XCTAssertTrue(item.previewPath?.contains("/versions/10/contents/") == true)
        XCTAssertFalse(accessed.contains { $0.contains("/scratch") || $0 == outside.path || $0.contains("/contents/link/") })
        XCTAssertFalse(snapshot.items.first { $0.path == system.path }!.isManaged)
        XCTAssertEqual(snapshot.items.first { $0.path == saved.path }?.location, .configurations)
        XCTAssertFalse(snapshot.items.first { $0.path == saved.path }!.isManaged)
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("preview.png")), Data([1]))
    }

    func testOwnershipSurvivesOSContentEditsButNeverAdoptsOtherFoldersOrSavedConfigurations() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try wallpaper(root, provider: provider, kind: "descriptors")
        let original = try record(path: owned, kind: "addWallpaper", date: 100)
        try Data("OS updated content".utf8).write(to: owned.appendingPathComponent("versions/10/contents/runtime"))
        let updated = try FileBackupStore.Snapshot(path: owned.path)
        XCTAssertTrue(WallpaperLibraryReader.owns(original, path: owned.path, snapshot: updated))
        let replacement = try wallpaper(root, provider: provider, kind: "descriptors")
        XCTAssertFalse(WallpaperLibraryReader.owns(original, path: owned.path, snapshot: try FileBackupStore.Snapshot(path: replacement.path)))
        XCTAssertFalse(WallpaperLibraryReader.owns(original, path: replacement.path, snapshot: updated))
        let unrelated = try record(path: replacement, kind: "importFile", date: 100)
        XCTAssertFalse(WallpaperLibraryReader.owns(unrelated, path: replacement.path, snapshot: try FileBackupStore.Snapshot(path: replacement.path)))
        let saved = try wallpaper(root, provider: provider, kind: "configurations")
        let notAnImport = try record(path: saved, kind: "addWallpaper", date: 100)
        let library = try await reader().load(container: root.path, backups: [original, notAnImport])
        XCTAssertEqual(library.items.filter(\.isManaged).map(\.path), [owned.path])
        // Earlier versions did not store WallpaperBackupMetadata; their successful imports still count.
        XCTAssertNil(original.manifest.wallpaper)
    }

    func testStandardAndSuggestedGalleryLocationsAreReadOnlyAndNotExcluded() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = try wallpaper(root, provider: provider, kind: "staticdescriptors", identifier: "standard")
        let suggestion = try wallpaper(root, provider: provider, kind: "suggestionDescriptors", identifier: "suggestion")
        // Even a record claiming these paths cannot make them app-managed.
        let records = try [record(path: standard, kind: "addWallpaper", date: 100),
                           record(path: suggestion, kind: "addWallpaper", date: 100)]
        let snapshot = try await reader().load(container: root.path, backups: records)
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.location.isGallery && !$0.isManaged })
        XCTAssertEqual(Set(snapshot.items.map(\.location.rawValue)), ["staticdescriptors", "suggestionDescriptors"])
        XCTAssertEqual(snapshot.diagnostics?.counters["accepted.staticdescriptors"], 1)
        XCTAssertEqual(snapshot.diagnostics?.counters["accepted.suggestionDescriptors"], 1)
        let device = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        for location in ["staticdescriptors", "suggestionDescriptors"] {
            let path = device + "/" + WallpaperPaths.store + "/Extensions/" + provider + "/" + location + "/" + UUID().uuidString
            XCTAssertTrue(try WallpaperPaths.installed(path).location.isGallery)
            XCTAssertThrowsError(try WallpaperPaths.validateDestination(URL(fileURLWithPath: path).deletingLastPathComponent().path))
        }
    }

    func testEmptyResultContainsActualRootNamesAndExclusionReasons() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensions = root.appendingPathComponent(WallpaperPaths.store + "/Extensions")
        let unsupported = extensions.appendingPathComponent("UnexpectedProvider")
        let providerRoot = extensions.appendingPathComponent(provider)
        let nonUUID = providerRoot.appendingPathComponent("descriptors/not-a-uuid")
        try FileManager.default.createDirectory(at: unsupported, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonUUID, withIntermediateDirectories: true)
        let snapshot = try await reader().load(container: root.path, backups: [])
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.unreadableCount, 0)
        let diagnostics = try XCTUnwrap(snapshot.diagnostics)
        XCTAssertEqual(diagnostics.counters["provider.entries"], 2)
        XCTAssertEqual(diagnostics.counters["provider.rejectedName"], 1)
        XCTAssertEqual(diagnostics.counters["candidate.rejectedID.descriptors"], 1)
        XCTAssertTrue(diagnostics.report.contains(extensions.path))
        XCTAssertTrue(diagnostics.report.contains("UnexpectedProvider"))
        XCTAssertTrue(diagnostics.report.contains("not-a-uuid"))
        XCTAssertTrue(diagnostics.report.contains(WallpaperLibraryDiagnostics.version))
    }

    func testEnumeratedButMissingChildrenCannotBecomeAnUnexplainedZeroCount() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try wallpaper(root, provider: provider, kind: "descriptors")
        let source = reader()
        let missing = WallpaperLibraryReader(list: source.list, read: source.read, inspect: { path in
            if path == installed.path { throw POSIXError(.ENOENT) }
            return try FileBackupStore.Snapshot(path: path)
        })
        do {
            _ = try await missing.load(container: root.path, backups: [])
            XCTFail("Missing enumerated children were accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("attribute.enumeratedButMissing=1"))
            XCTAssertTrue(error.localizedDescription.contains(installed.path))
            XCTAssertTrue(error.localizedDescription.contains("一覧に存在する項目"))
        }
    }

    func testDiagnosticTraceIsBoundedAndDoesNotReadWallpaperContents() async throws {
        var diagnostics = WallpaperLibraryDiagnostics(container: "/container", extensionsPath: "/container/Extensions")
        for _ in 0..<1_000 { diagnostics.record(String(repeating: "記録", count: 1_000)) }
        XCTAssertLessThanOrEqual(diagnostics.events.count, 200)
        XCTAssertLessThan(diagnostics.report.utf8.count, 52 * 1024)
        XCTAssertGreaterThan(diagnostics.omittedEvents, 0)
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try wallpaper(root, provider: provider, kind: "descriptors")
        let secret = "PRIVATE_IMAGE_CONTENT_DO_NOT_LOG"
        let image = installed.appendingPathComponent("versions/10/contents/Example.wallpaper/Background.HEIC")
        try Data(secret.utf8).write(to: image)
        var reads: [String] = []
        let source = reader()
        let inspected = WallpaperLibraryReader(list: source.list, read: { path, maximum in
            reads.append(path)
            return try await source.read(path, maximum)
        })
        let snapshot = try await inspected.load(container: root.path, backups: [])
        XCTAssertFalse(reads.contains(image.path))
        XCTAssertFalse(snapshot.diagnostics!.report.contains(secret))
    }

    func testDirectoryNamesRemainDiscoverableWhenPrefetchedMetadataIsUnavailable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try wallpaper(root, provider: provider, kind: "descriptors", asset: "9183.Nebula-810w-1080h@2x~ipad.wallpaper")
        let saved = try wallpaper(root, provider: provider, kind: "configurations")
        let source = reader()
        var inspected: [String] = []
        let namesOnly = WallpaperLibraryReader(list: { path in
            try await source.list(path).map {
                // listContents retains names but falls back to these false/zero
                // fields when URL resource values and child attributes are denied.
                FileEntry(path: $0.path, name: $0.name, isDirectory: false, isSymbolicLink: false, size: 0, modified: nil)
            }
        }, read: source.read, inspect: { path in
            inspected.append(path)
            return try FileBackupStore.Snapshot(path: path)
        })
        let snapshot = try await namesOnly.load(container: root.path, backups: [])
        XCTAssertEqual(snapshot.items.count, 2)
        let gallery = try XCTUnwrap(snapshot.items.first { $0.path == installed.path })
        XCTAssertEqual(gallery.title, "Nebula")
        XCTAssertNotNil(gallery.previewPath)
        XCTAssertEqual(snapshot.items.first { $0.path == saved.path }?.location, .configurations)
        XCTAssertTrue(inspected.contains(root.appendingPathComponent(WallpaperPaths.store + "/Extensions/" + provider).path))
        XCTAssertTrue(inspected.contains(installed.path))
        XCTAssertTrue(inspected.contains(installed.appendingPathComponent("versions/10").path))
        XCTAssertEqual(snapshot.unreadableCount, 0)
    }

    func testDeniedChildAttributesAreReportedInsteadOfReturningAnEmptyGallery() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try wallpaper(root, provider: provider, kind: "descriptors")
        let source = reader()
        let denied = WallpaperLibraryReader(list: source.list, read: source.read, inspect: { path in
            if path == installed.path { throw POSIXError(.EACCES) }
            return try FileBackupStore.Snapshot(path: path)
        })
        do {
            _ = try await denied.load(container: root.path, backups: [])
            XCTFail("Attribute denial became an empty gallery")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("0件と確認できたわけではありません"))
            XCTAssertTrue(error.localizedDescription.contains(installed.path))
            XCTAssertTrue(error.localizedDescription.contains("属性の取得"))
            XCTAssertTrue(error.localizedDescription.contains(NSPOSIXErrorDomain))
        }
    }

    func testPartiallyDeniedGalleryKeepsReadableItemsAndIncludesFailureDetails() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let readable = try wallpaper(root, provider: provider, kind: "descriptors")
        let deniedPath = try wallpaper(root, provider: provider, kind: "descriptors")
        let source = reader()
        let partial = WallpaperLibraryReader(list: source.list, read: source.read, inspect: { path in
            if path == deniedPath.path { throw POSIXError(.EPERM) }
            return try FileBackupStore.Snapshot(path: path)
        })
        let snapshot = try await partial.load(container: root.path, backups: [])
        XCTAssertEqual(snapshot.items.map(\.path), [readable.path])
        XCTAssertEqual(snapshot.unreadableCount, 1)
        XCTAssertEqual(snapshot.issues.first?.path, deniedPath.path)
        XCTAssertTrue(snapshot.issues.first?.message.contains(NSPOSIXErrorDomain) == true)
    }

    func testUntrustedMetadataHintsNeverCauseSymbolicLinksToBeTraversed() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try wallpaper(root, provider: provider, kind: "descriptors")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: installed.appendingPathComponent("versions/10/contents/linked.wallpaper"), withDestinationURL: outside)
        let source = reader()
        var listed: [String] = []
        let wrongHints = WallpaperLibraryReader(list: { path in
            listed.append(path)
            return try await source.list(path).map {
                FileEntry(path: $0.path, name: $0.name, isDirectory: true, isSymbolicLink: false, size: 0, modified: nil)
            }
        }, read: source.read)
        let snapshot = try await wrongHints.load(container: root.path, backups: [])
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertFalse(listed.contains { $0.contains("linked.wallpaper") || $0 == outside.path })
    }

    func testRefreshFailureIsDistinguishedFromManualRespringAndRetry() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try wallpaper(root, provider: provider, kind: "descriptors")
        let id = UUID()
        let metadata = WallpaperBackupMetadata(changeID: id, title: "A", package: "A.tendie", isRefresh: false)
        let imported = try record(path: owned, kind: "addWallpaper", date: 100, metadata: metadata)
        let refreshPath = root.appendingPathComponent("Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let refreshMetadata = WallpaperBackupMetadata(changeID: id, title: "A", package: "A.tendie", isRefresh: true)
        let failed = try record(path: refreshPath, kind: "savePropertyList", date: 101, succeeded: false, metadata: refreshMetadata)
        let oldRefresh = try record(path: refreshPath, kind: "savePropertyList", date: 99, metadata: refreshMetadata)
        let pending = try await reader().load(container: root.path, backups: [imported, failed, oldRefresh])
        XCTAssertTrue(pending.refreshRequired)
        XCTAssertEqual(pending.latestChange, Date(timeIntervalSince1970: 100))
        let retry = try record(path: refreshPath, kind: "savePropertyList", date: 102, metadata: refreshMetadata)
        let ready = try await reader().load(container: root.path, backups: [imported, failed, retry])
        XCTAssertFalse(ready.refreshRequired)
        XCTAssertEqual(ready.latestChange, Date(timeIntervalSince1970: 102))
        let standalone = try await reader().load(container: root.path, backups: [retry])
        XCTAssertFalse(standalone.refreshRequired)
        XCTAssertNotNil(standalone.latestChange)
    }

    func testBothBackupsMustSucceedBeforeImportAndMetadataIsPersistent() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try transactionFixture(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var attempts = 0, wrote = false
        XCTAssertThrowsError(try WallpaperWriteTransaction.perform(operation: fixture.operation, source: fixture.source,
            destination: fixture.destination, change: fixture.change, store: store, preflight: {}, backup: { operation, source, destination, metadata in
                attempts += 1
                if attempts == 2 { throw RunnerError("Settings backup failed") }
                return try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
            }, writePrimary: { _ in wrote = true }, writeRefresh: { _ in wrote = true }))
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.change.refresh.path)), fixture.change.refresh.original)
        let incomplete = try XCTUnwrap(store.list().records.first)
        XCTAssertEqual(incomplete.outcome?.succeeded, false)
        XCTAssertEqual(incomplete.manifest.wallpaper?.changeID, fixture.change.metadata.changeID)
        XCTAssertEqual(incomplete.manifest.wallpaper?.package, "A.tendie")
    }

    func testSuccessfulTransactionImportsAndUpdatesSettingsWithTwoRecoverableBackups() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try transactionFixture(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        _ = try WallpaperWriteTransaction.perform(operation: fixture.operation, source: fixture.source,
            destination: fixture.destination, change: fixture.change, store: store, preflight: {}, backup: { operation, source, destination, metadata in
                try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
            }, writePrimary: { backup in
                XCTAssertEqual(try store.list().records.count, 2)
                try FileManager.default.copyItem(at: backup.payload, to: fixture.destination)
            }, writeRefresh: { _ in
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
                try fixture.change.refresh.data.write(to: URL(fileURLWithPath: fixture.change.refresh.path))
            })
        let records = try store.list().records
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.outcome?.succeeded == true })
        let imported = try XCTUnwrap(records.first { $0.manifest.operationKind == "addWallpaper" })
        let refresh = try XCTUnwrap(records.first { $0.manifest.wallpaper?.isRefresh == true })
        XCTAssertTrue(WallpaperLibraryReader.owns(imported, path: fixture.destination.path, snapshot: try FileBackupStore.Snapshot(path: fixture.destination.path)))
        XCTAssertEqual(try Data(contentsOf: refresh.payload), fixture.change.refresh.original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.change.refresh.path)), fixture.change.refresh.data)
        XCTAssertEqual(imported.manifest.wallpaper?.changeID, refresh.manifest.wallpaper?.changeID)
        guard case .removeCreated = try imported.restoration(), case .original = try refresh.restoration() else { return XCTFail("Backups are not restorable") }
    }

    func testRefreshFailureKeepsSuccessfulImportOwnershipAndReportsPartialResult() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try transactionFixture(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        do {
            _ = try WallpaperWriteTransaction.perform(operation: fixture.operation, source: fixture.source,
                destination: fixture.destination, change: fixture.change, store: store, preflight: {}, backup: { operation, source, destination, metadata in
                    try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
                }, writePrimary: { try FileManager.default.copyItem(at: $0.payload, to: fixture.destination) },
                writeRefresh: { _ in throw RunnerError("Settings changed externally") })
            XCTFail("Refresh failure ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("壁紙の変更は完了")) }
        let records = try store.list().records
        XCTAssertEqual(records.first { $0.manifest.operationKind == "addWallpaper" }?.outcome?.succeeded, true)
        XCTAssertEqual(records.first { $0.manifest.wallpaper?.isRefresh == true }?.outcome?.succeeded, false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.change.refresh.path)), fixture.change.refresh.original)
    }

    func testExternalChangeAfterBackupPreventsBothWrites() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try transactionFixture(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var wrote = false
        XCTAssertThrowsError(try WallpaperWriteTransaction.perform(operation: fixture.operation, source: fixture.source,
            destination: fixture.destination, change: fixture.change, store: store, preflight: {}, backup: { operation, source, destination, metadata in
                let backup = try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
                if metadata.isRefresh { try Data("external change".utf8).write(to: fixture.source.appendingPathComponent("asset")) }
                return backup
            }, writePrimary: { _ in wrote = true }, writeRefresh: { _ in wrote = true }))
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.change.refresh.path)), fixture.change.refresh.original)
    }

    func testDeletionBacksUpCurrentContentsAndCanRestoreDirectory() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try transactionFixture(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        let removed = try WallpaperWriteTransaction.perform(operation: .delete(path: fixture.source.path), source: fixture.source,
            destination: nil, change: fixture.change, store: store, preflight: {}, backup: { operation, source, destination, metadata in
                try store.prepare(operation: operation, source: source, destination: destination, wallpaper: metadata)
            }, writePrimary: { _ in try FileManager.default.removeItem(at: fixture.source) },
            writeRefresh: { _ in try fixture.change.refresh.data.write(to: URL(fileURLWithPath: fixture.change.refresh.path)) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: removed.payload.appendingPathComponent("asset")), Data("asset".utf8))
        let manager = FileAccessManager(backupRoot: store.root)
        let restore = try await manager.prepareWrite(.restoreBackup(id: removed.directory.lastPathComponent))
        _ = try await manager.commitWrite(restore, userConsented: true)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("asset")), Data("asset".utf8))
    }

    func testThumbnailIsBoundedAndInvalidImagesAreOptional() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let thumbnail = try XCTUnwrap(WallpaperThumbnail.make(bytes as Data))
        XCTAssertLessThan(thumbnail.count, 1_048_576)
        XCTAssertNil(try WallpaperThumbnail.make(Data("not an image".utf8)))
        XCTAssertNil(try WallpaperThumbnail.make(Data(count: WallpaperThumbnail.maximumBytes + 1)))
    }

    @MainActor
    func testLateAndBackgroundedLoadsNeverReplaceCurrentLibrary() async {
        let model = WallpaperLibraryModel(), gate = WallpaperGate()
        let started = expectation(description: "Started")
        let empty = WallpaperLibrarySnapshot(items: [], unreadableCount: 0, latestChange: nil, refreshRequired: false)
        let old = Task {
            await model.load {
                started.fulfill()
                await gate.wait()
                return WallpaperLibraryLoad(container: "old", storePath: nil, snapshot: empty)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.load { WallpaperLibraryLoad(container: "new", storePath: nil, snapshot: empty) }
        await gate.open()
        await old.value
        XCTAssertEqual(model.result?.container, "new")
        XCTAssertFalse(model.loading)
        let backgroundGate = WallpaperGate()
        let loading = expectation(description: "Background load started")
        let backgrounded = Task {
            await model.load {
                loading.fulfill()
                await backgroundGate.wait()
                return WallpaperLibraryLoad(container: "backgrounded", storePath: nil, snapshot: empty)
            }
        }
        await fulfillment(of: [loading], timeout: 2)
        model.cancel()
        await backgroundGate.open()
        await backgrounded.value
        XCTAssertNil(model.result)
        await model.load { throw RunnerError("Unavailable") }
        XCTAssertNil(model.result)
        XCTAssertEqual(model.error, "Unavailable")
    }

    func testLibraryBoundsAndCancellationNeverReturnASeeminglyCompleteList() async throws {
        let item = FileEntry(path: "/unused", name: "x", isDirectory: false, isSymbolicLink: false, size: 0, modified: nil)
        let huge = WallpaperLibraryReader(list: { _ in Array(repeating: item, count: 30_001) }, read: { _, _ in Data() })
        do {
            _ = try await huge.load(container: "/unused", backups: [])
            XCTFail("Traversal limit ignored")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("30,000"))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await huge.load(container: "/unused", backups: [])
        }
        do { _ = try await task.value; XCTFail("Cancelled library returned") } catch is CancellationError {}
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperLibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func wallpaper(_ root: URL, provider: String, kind: String, identifier: String = "7420", asset: String = "Example.wallpaper") throws -> URL {
        let path = root.appendingPathComponent(WallpaperPaths.store + "/Extensions/" + provider + "/" + kind + "/" + UUID().uuidString)
        let contents = path.appendingPathComponent("versions/10/contents/" + asset)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(identifier.utf8).write(to: path.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"))
        try Data([1]).write(to: contents.appendingPathComponent("Background.HEIC"))
        return path
    }

    private func record(path: URL, kind: String, date: TimeInterval, succeeded: Bool = true,
                        snapshot: FileBackupStore.Snapshot? = nil, metadata: WallpaperBackupMetadata? = nil) throws -> FileBackupRecord {
        let state = try snapshot ?? (FileManager.default.fileExists(atPath: path.path) ? FileBackupStore.Snapshot(path: path.path) : nil)
        let imported = kind == "addWallpaper"
        let manifest = FileBackupManifest(version: 2, created: Date(timeIntervalSince1970: date), operation: kind, kind: kind,
            sourcePath: imported ? nil : path.path, destinationPath: imported ? path.path : nil,
            destinationWasAbsent: imported, parent: nil, entries: [:], hashes: [:], wallpaper: metadata)
        return FileBackupRecord(id: UUID().uuidString, directory: path, manifest: manifest,
                               outcome: FileBackupOutcome(succeeded: succeeded, changedPath: path.path, snapshot: state.map { [".": $0] }))
    }

    private func reader(onList: @escaping (String) -> Void = { _ in }) -> WallpaperLibraryReader {
        WallpaperLibraryReader(list: { path in
            onList(path)
            return try FileManager.default.contentsOfDirectory(atPath: path).map { name in
                let child = URL(fileURLWithPath: path).appendingPathComponent(name)
                let info = try FileBackupStore.Snapshot(path: child.path)
                return FileEntry(path: child.path, name: name, isDirectory: info.isDirectory, isSymbolicLink: !info.isRegular && !info.isDirectory,
                                 size: info.size, modified: nil)
            }
        }, read: { path, maximum in try StableFileReader.read(path: path, maximumBytes: maximum) { $0 } })
    }

    private func transactionFixture(_ root: URL) throws -> (source: URL, destination: URL, operation: FileWriteOperation, change: PendingWallpaperChange) {
        let source = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("asset".utf8).write(to: source.appendingPathComponent("asset"))
        let destination = root.appendingPathComponent(UUID().uuidString)
        let settings = root.appendingPathComponent("settings.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["preserve": "yes"], format: .binary, options: 0)
        try original.write(to: settings)
        let refresh = WallpaperRefresh(path: settings.path, original: original, data: try WallpaperImporter.refreshSettings(original))
        let change = PendingWallpaperChange(refresh: refresh,
            metadata: WallpaperBackupMetadata(changeID: UUID(), title: "A", package: "A.tendie", isRefresh: false), removal: nil)
        return (source, destination, .addWallpaper(source: source, directory: root.path), change)
    }
}

private actor WallpaperGate {
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
