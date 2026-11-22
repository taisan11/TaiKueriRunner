import XCTest
@testable import RunnerCore

final class FileAccessManagerTests: XCTestCase {
    func testWritingRequiresPerOperationConsent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let request = try await manager.prepareWrite(.delete(path: root.appendingPathComponent("file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
        do { _ = try await manager.commitWrite(request, userConsented: false); XCTFail("Missing consent accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
    }

    func testCancelledAndUsedRequestsCannotBeReplayed() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let cancelled = try await manager.prepareWrite(.delete(path: root.appendingPathComponent("file").path))
        await manager.cancelWrite(cancelled)
        do { _ = try await manager.commitWrite(cancelled, userConsented: true); XCTFail("Cancelled request accepted") } catch {}
        let used = try await manager.prepareWrite(.rename(path: root.appendingPathComponent("file").path, name: "renamed"))
        _ = try await manager.commitWrite(used, userConsented: true)
        do { _ = try await manager.commitWrite(used, userConsented: true); XCTFail("Request replay accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))
    }

    func testBackupFailurePreventsEveryMutation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let manager = FileAccessManager(backupRoot: blocker.appendingPathComponent("Backups"))
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for operation: FileWriteOperation in [.saveText(path: file.path, text: "changed", original: "original"),
                                              .rename(path: file.path, name: "renamed"), .delete(path: file.path),
                                              .createFolder(name: "new", directory: root.path),
                                              .importFile(source: file, directory: destination.path)] {
            do { _ = try await commit(operation, manager: manager); XCTFail("Mutation ran despite backup failure") } catch {}
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testDeletionBacksUpDirectoryIncludingHiddenFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("hidden".utf8).write(to: directory.appendingPathComponent(".hidden"))
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let receipt = try await commit(.delete(path: directory.path), manager: manager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: receipt.backupDirectory.appendingPathComponent("original/.hidden"), encoding: .utf8), "hidden")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt.backupDirectory.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["sourcePath"] as? String, directory.path)
        XCTAssertEqual(manifest["operation"] as? String, "削除")
    }

    func testNewFolderRecordsAbsentDestinationAndImportPreservesSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let folder = try await commit(.createFolder(name: "new", directory: root.path), manager: manager)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.backupDirectory.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["destinationWasAbsent"] as? Bool, true)
        XCTAssertNotNil(manifest["parent"])
        let receipt = try await commit(.importFile(source: root.appendingPathComponent("file"), directory: root.appendingPathComponent("new").path), manager: manager)
        for path in [root.appendingPathComponent("file"), root.appendingPathComponent("new/file"), receipt.backupDirectory.appendingPathComponent("original")] {
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original")
        }
        do {
            _ = try await commit(.importFile(source: root.appendingPathComponent("file"), directory: root.appendingPathComponent("new").path), manager: manager)
            XCTFail("Existing import was overwritten")
        } catch {}
    }

    func testRenameDoesNotOverwriteAndHasOriginalBackup() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let file = root.appendingPathComponent("file")
        try Data("existing".utf8).write(to: root.appendingPathComponent("existing"))
        do { _ = try await commit(.rename(path: file.path, name: "existing"), manager: manager); XCTFail("Overwrote existing file") } catch {}
        let receipt = try await commit(.rename(path: file.path, name: "renamed"), manager: manager)
        XCTAssertEqual(try String(contentsOf: receipt.backupDirectory.appendingPathComponent("original"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("existing"), encoding: .utf8), "existing")
    }

    func testBackupAreaAndAncestorsAreProtectedIncludingAliases() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backups)
        let manager = FileAccessManager(backupRoot: backups)
        for path in ["/", root.path, backups.path, alias.path, backups.appendingPathComponent("anything").path] {
            do { _ = try await manager.prepareWrite(.delete(path: path)); XCTFail("Backup protection bypassed: \(path)") } catch {}
        }
    }

    func testLinksAndOversizedBackupsFailWithoutDeletingSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("file"))
        do { _ = try await commit(.delete(path: directory.path), manager: manager); XCTFail("Directory with link deleted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let large = root.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FileBackupStore.maximumBytes + 1))
        try handle.close()
        do { _ = try await commit(.delete(path: large.path), manager: manager); XCTFail("Oversized file deleted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: large.path))
    }

    func testCancellationBeforeCommitLeavesSourceUntouched() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let request = try await manager.prepareWrite(.delete(path: root.appendingPathComponent("file").path))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await manager.commitWrite(request, userConsented: true)
        }
        do { _ = try await task.value; XCTFail("Cancelled write succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("file").path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileAccessManagerTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        return root
    }

    private func commit(_ operation: FileWriteOperation, manager: FileAccessManager) async throws -> FileWriteReceipt {
        let request = try await manager.prepareWrite(operation)
        return try await manager.commitWrite(request, userConsented: true)
    }
}
