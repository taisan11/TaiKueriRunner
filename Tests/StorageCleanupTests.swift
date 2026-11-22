import XCTest
@testable import RunnerCore

final class StorageCleanupTests: XCTestCase {
    func testUsageAndCleanupOnlyTouchKnownStagingAndCacheEntries() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)

        let export = temporary.appendingPathComponent("ApplicationDataExport-\(UUID().uuidString)")
        let keypad = temporary.appendingPathComponent("KeypadExport-\(UUID().uuidString)")
        let unrelated = temporary.appendingPathComponent("Unrelated-\(UUID().uuidString)")
        let malformed = temporary.appendingPathComponent("ApplicationDataExport-not-a-uuid")
        for directory in [export, keypad, unrelated, malformed] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data(repeating: 1, count: 1_000).write(to: export.appendingPathComponent("data.zip"))
        try Data(repeating: 2, count: 200).write(to: keypad.appendingPathComponent("keys.zip"))
        try Data(repeating: 3, count: 300).write(to: unrelated.appendingPathComponent("keep"))
        try Data(repeating: 4, count: 50).write(to: malformed.appendingPathComponent("keep"))

        let metal = caches.appendingPathComponent("com.apple.metal")
        try FileManager.default.createDirectory(at: metal, withIntermediateDirectories: false)
        try Data(repeating: 5, count: 300).write(to: metal.appendingPathComponent("libraries.data"))
        try Data(repeating: 6, count: 100).write(to: caches.appendingPathComponent("cache.db"))

        let store = AppCacheStore(temporaryRoot: temporary, cachesRoot: caches)
        let usage = store.usage()
        XCTAssertEqual(usage.temporaryItems, 2)
        XCTAssertEqual(usage.temporaryBytes, 1_200)
        XCTAssertEqual(usage.cacheItems, 2)
        XCTAssertEqual(usage.cacheBytes, 400)
        XCTAssertEqual(usage.totalBytes, 1_600)

        let result = store.cleanup()
        XCTAssertEqual(result.removedItems, 4)
        XCTAssertEqual(result.failedItems, 0)
        XCTAssertEqual(result.freedBytes, 1_600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keypad.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("cache.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.path))
    }

    func testCleanupRemovesAppGroupExportStaging() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        let staging = temporary.appendingPathComponent("AppGroupDataExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(repeating: 9, count: 250).write(to: staging.appendingPathComponent("group-data.zip"))

        let store = AppCacheStore(temporaryRoot: temporary, cachesRoot: caches)
        XCTAssertEqual(store.usage().temporaryBytes, 250)
        let result = store.cleanup()
        XCTAssertEqual(result.freedBytes, 250)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testPurgeKeepsRecentAndActiveStagingPlusCacheEntries() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)

        let old = temporary.appendingPathComponent("DocumentPreview-\(UUID().uuidString)")
        let recent = temporary.appendingPathComponent("SQLitePreview-\(UUID().uuidString)")
        let active = temporary.appendingPathComponent("WallpaperImport-\(UUID().uuidString)")
        for directory in [old, recent, active] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data(repeating: 1, count: 500).write(to: old.appendingPathComponent("old"))
        try Data(repeating: 2, count: 600).write(to: recent.appendingPathComponent("recent"))
        try Data(repeating: 3, count: 700).write(to: active.appendingPathComponent("active"))
        let past = Date(timeIntervalSinceNow: -90_000)
        for directory in [old, active] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: directory.path)
        }
        try Data(repeating: 4, count: 100).write(to: caches.appendingPathComponent("cache.bin"))

        let store = AppCacheStore(temporaryRoot: temporary, cachesRoot: caches)
        let result = store.purgeStaging(olderThan: 3_600, activeDirectories: [active])
        XCTAssertEqual(result.removedItems, 1)
        XCTAssertEqual(result.failedItems, 0)
        XCTAssertEqual(result.freedBytes, 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("cache.bin").path))
    }

    func testCleanupDoesNotFollowStagingSymlinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside.txt")
        let outsideData = Data(repeating: 7, count: 1_234)
        try outsideData.write(to: outside)
        let staging = temporary.appendingPathComponent("ApplicationDataExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(repeating: 8, count: 100).write(to: staging.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("link"), withDestinationURL: outside)

        let result = AppCacheStore(temporaryRoot: temporary, cachesRoot: caches).cleanup()
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
    }

    func testManagerAutoPurgeKeepsActiveStagingAndRemovesOldOrphans() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp")
        let caches = root.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt")
        try Data("preview".utf8).write(to: source)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"),
                                        temporaryRoot: temporary, cachesRoot: caches)
        let staged = try await manager.stageDocumentPreview(path: source.path, maximumBytes: 100)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)],
                                              ofItemAtPath: staged.directory.path)
        let orphan = temporary.appendingPathComponent("ApplicationDataExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 100).write(to: orphan.appendingPathComponent("orphan"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)],
                                              ofItemAtPath: orphan.path)

        let result = await manager.purgeOrphanedStagingFiles()
        XCTAssertEqual(result.removedItems, 1)
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        await manager.closeDocumentPreview(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }

    func testDeletingBackupsRejectsPendingRestoreAndLeavesOtherBackups() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let file = root.appendingPathComponent("file")
        try Data("original".utf8).write(to: file)
        let first = try await commit(.saveText(path: file.path, text: "first", original: "original"), manager)
        let second = try await commit(.saveText(path: file.path, text: "second", original: "first"), manager)
        let firstID = first.backupDirectory.lastPathComponent
        let secondID = second.backupDirectory.lastPathComponent

        let pending = try await manager.prepareWrite(.restoreBackup(id: firstID))
        do {
            _ = try await manager.deleteBackups(ids: [firstID])
            XCTFail("A backup with a pending restore was deleted")
        } catch {}
        await manager.cancelWrite(pending)

        let result = try await manager.deleteBackups(ids: [firstID])
        XCTAssertEqual(result.removed, [firstID])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.backupDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.backupDirectory.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
        let remaining = try await manager.backups().records.map(\.id)
        XCTAssertEqual(remaining, [secondID])
    }

    func testInvalidBackupIDsAreReportedWithoutTouchingOtherDirectories() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: backups.appendingPathComponent("not-a-backup"))
        let manager = FileAccessManager(backupRoot: backups)
        let result = try await manager.deleteBackups(ids: ["../file", UUID().uuidString])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed.count, 2)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appendingPathComponent("not-a-backup").path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageCleanupTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func commit(_ operation: FileWriteOperation, _ manager: FileAccessManager) async throws -> FileWriteReceipt {
        let request = try await manager.prepareWrite(operation)
        return try await manager.commitWrite(request, userConsented: true)
    }
}
