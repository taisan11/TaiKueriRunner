import XCTest
@testable import RunnerCore

final class BackupRestorationTests: XCTestCase {
    func testRestoringEditedFilePreservesInodeAndBacksUpCurrentValue() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let file = root.appendingPathComponent("file")
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let original = try await commit(.saveText(path: file.path, text: "changed", original: "original"), manager)
        let restored = try await commit(.restoreBackup(id: original.backupDirectory.lastPathComponent), manager)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: restored.backupDirectory.appendingPathComponent("original"), encoding: .utf8), "changed")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
        _ = try await commit(.restoreBackup(id: restored.backupDirectory.lastPathComponent), manager)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    func testRestoreDeletedDirectoryAndUndoRestoration() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden"))
        let deletion = try await commit(.delete(path: directory.path), manager)
        let restoration = try await commit(.restoreBackup(id: deletion.backupDirectory.lastPathComponent), manager)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".hidden"), encoding: .utf8), "hidden")
        _ = try await commit(.restoreBackup(id: restoration.backupDirectory.lastPathComponent), manager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRenameRestoresOriginalPathWithoutRemovingRenamedItem() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let receipt = try await commit(.rename(path: root.appendingPathComponent("file").path, name: "renamed"), manager)
        _ = try await commit(.restoreBackup(id: receipt.backupDirectory.lastPathComponent), manager)
        for name in ["file", "renamed"] { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8), "original") }
    }

    func testUndoCreationAndImportRejectsSubsequentChanges() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let creation = try await commit(.createFolder(name: "new", directory: root.path), manager)
        let imported = try await commit(.importFile(source: root.appendingPathComponent("file"), directory: root.appendingPathComponent("new").path), manager)
        do { _ = try await commit(.restoreBackup(id: creation.backupDirectory.lastPathComponent), manager); XCTFail("Changed folder was deleted") } catch {}
        let target = root.appendingPathComponent("new/file")
        try Data("user edit".utf8).write(to: target)
        do { _ = try await commit(.restoreBackup(id: imported.backupDirectory.lastPathComponent), manager); XCTFail("Changed import was deleted") } catch {}
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "user edit")
        let empty = try await commit(.createFolder(name: "empty", directory: root.path), manager)
        _ = try await commit(.restoreBackup(id: empty.backupDirectory.lastPathComponent), manager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path))
    }

    func testUndoUnchangedImportDoesNotAffectSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let imported = try await commit(.importFile(source: root.appendingPathComponent("file"), directory: folder.path), manager)
        _ = try await commit(.restoreBackup(id: imported.backupDirectory.lastPathComponent), manager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("file").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file"), encoding: .utf8), "original")
    }

    func testTamperedPayloadAndDirectoryConflictFailWithoutMutation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let file = root.appendingPathComponent("file")
        let receipt = try await commit(.saveText(path: file.path, text: "changed", original: "original"), manager)
        try Data("tampered".utf8).write(to: receipt.backupDirectory.appendingPathComponent("original"))
        do { _ = try await commit(.restoreBackup(id: receipt.backupDirectory.lastPathComponent), manager); XCTFail("Tampered data restored") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
        let directory = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let deletion = try await commit(.delete(path: directory.path), manager)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("new work".utf8).write(to: directory.appendingPathComponent("new"))
        do { _ = try await commit(.restoreBackup(id: deletion.backupDirectory.lastPathComponent), manager); XCTFail("Conflicting directory replaced") } catch {}
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new"), encoding: .utf8), "new work")
    }

    func testLegacyManifestRestoresOriginalButDoesNotDeleteUnverifiedCreation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let file = root.appendingPathComponent("file")
        let receipt = try await commit(.saveText(path: file.path, text: "changed", original: "original"), manager)
        try downgradeToLegacy(receipt)
        _ = try await commit(.restoreBackup(id: receipt.backupDirectory.lastPathComponent), manager)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        let creation = try await commit(.createFolder(name: "legacy", directory: root.path), manager)
        try downgradeToLegacy(creation)
        do { _ = try await manager.prepareWrite(.restoreBackup(id: creation.backupDirectory.lastPathComponent)); XCTFail("Unverified creation could be removed") } catch {}
    }

    func testRestoreStillRequiresConsentAndSuccessfulCurrentStateBackup() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appendingPathComponent("Backups")
        let manager = FileAccessManager(backupRoot: backups)
        let file = root.appendingPathComponent("file")
        let receipt = try await commit(.saveText(path: file.path, text: "changed", original: "original"), manager)
        let request = try await manager.prepareWrite(.restoreBackup(id: receipt.backupDirectory.lastPathComponent))
        do { _ = try await manager.commitWrite(request, userConsented: false); XCTFail("Consent bypassed") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backups.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path) }
        do { _ = try await commit(.restoreBackup(id: receipt.backupDirectory.lastPathComponent), manager); XCTFail("Restore ran without re-backup") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    func testListingRejectsTraversalAndCountsMalformedRecords() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appendingPathComponent("Backups")
        let manager = FileAccessManager(backupRoot: backups)
        let empty = try await manager.backups()
        XCTAssertTrue(empty.records.isEmpty)
        _ = try await commit(.saveText(path: root.appendingPathComponent("file").path, text: "changed", original: "original"), manager)
        try Data("bad record".utf8).write(to: backups.appendingPathComponent("invalid"))
        let listing = try await manager.backups()
        XCTAssertEqual(listing.records.count, 1)
        XCTAssertEqual(listing.unreadableCount, 1)
        do { _ = try await manager.prepareWrite(.restoreBackup(id: "../file")); XCTFail("Traversal accepted") } catch {}
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRestorationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        return root
    }

    private func commit(_ operation: FileWriteOperation, _ manager: FileAccessManager) async throws -> FileWriteReceipt {
        let request = try await manager.prepareWrite(operation)
        return try await manager.commitWrite(request, userConsented: true)
    }

    private func downgradeToLegacy(_ receipt: FileWriteReceipt) throws {
        let url = receipt.backupDirectory.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest["version"] = 1; manifest.removeValue(forKey: "kind"); manifest.removeValue(forKey: "hashes")
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        try FileManager.default.removeItem(at: receipt.backupDirectory.appendingPathComponent("outcome.json"))
    }
}
