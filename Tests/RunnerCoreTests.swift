import XCTest
@testable import RunnerCore

final class RunnerCoreTests: XCTestCase {
    func testUnavailableGroupFallsBackToAccessibleSignedGroup() {
        var queried: [String] = []
        let selected = AppGroupSelection.resolve(entitledGroups: ["group.denied", "group.allowed", "group.unused"]) {
            queried.append($0)
            return $0 == "group.allowed" ? URL(fileURLWithPath: "/fixture/allowed") : nil
        }
        XCTAssertEqual(selected?.identifier, "group.allowed")
        XCTAssertEqual(selected?.containerURL.path, "/fixture/allowed")
        XCTAssertEqual(queried, ["group.denied", "group.allowed"])
    }

    func testMissingEntitlementsNeverProbeAnUnsignedGroup() {
        let selected = AppGroupSelection.resolve(entitledGroups: []) { _ in
            XCTFail("Only signed groups may be probed")
            return URL(fileURLWithPath: "/fixture")
        }
        XCTAssertNil(selected)
    }

    func testInvalidAndDuplicateGroupsAreNotProbed() {
        var queried: [String] = []
        let selected = AppGroupSelection.resolve(
            entitledGroups: ["", "group.*", "$(APP_GROUP_IDENTIFIER)", "group.denied", "group.denied"]
        ) {
            queried.append($0)
            return nil
        }
        XCTAssertNil(selected)
        XCTAssertEqual(queried, ["group.denied"])
    }

    func testSupportedVersions() {
        for (major, minor, patch) in [(26, 0, 0), (26, 7, 2), (27, 0, 0), (27, 2, 0), (27, 2, 1)] {
            XCTAssertTrue(RuntimeSupport.isReportedSupported(.init(majorVersion: major, minorVersion: minor, patchVersion: patch)))
        }
        for (major, minor, patch) in [(25, 9, 0), (26, 7, 3), (26, 8, 0), (27, 2, 2), (27, 3, 0), (28, 0, 0)] {
            XCTAssertFalse(RuntimeSupport.isReportedSupported(.init(majorVersion: major, minorVersion: minor, patchVersion: patch)))
        }
    }

    func testCanonicalPathsAndInvalidInput() throws {
        XCTAssertEqual(try FileRules.canonical("/var/mobile/../mobile/"), "/var/mobile")
        XCTAssertEqual(try FileRules.canonical("/"), "/")
        XCTAssertThrowsError(try FileRules.canonical("relative/path"))
        XCTAssertThrowsError(try FileRules.canonical(""))
        XCTAssertThrowsError(try FileRules.canonical("/var/\0foo"))
    }

    func testChildNamesCannotTraverse() throws {
        for name in ["", ".", "..", "../escape", "/absolute", "folder/name", "a\0b"] {
            XCTAssertThrowsError(try FileRules.child(name, in: "/var/mobile"))
        }
        XCTAssertEqual(try FileRules.child("日本語.txt", in: "/var/mobile").path, "/var/mobile/日本語.txt")
    }

    func testListingHiddenFilesAndFoldersFirst() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("z-folder"), withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("a-file"))
        try Data().write(to: directory.appendingPathComponent(".hidden"))
        let service = FileAccessManager()
        let visible = try await service.list(path: directory.path, showHidden: false)
        let sorted = try await FileListingWorker().apply(visible, search: "", options: .init())
        XCTAssertEqual(sorted.map(\.name), ["z-folder", "a-file"])
        let all = try await service.list(path: directory.path, showHidden: true)
        XCTAssertEqual(all.count, 3)
    }

    func testTextPreviewRejectsBinaryAndLargeFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("binary")
        let large = directory.appendingPathComponent("large")
        try Data([0xff, 0x00, 0xfe]).write(to: binary)
        try Data(repeating: 65, count: 1_048_577).write(to: large)
        let service = FileAccessManager()
        do { _ = try await service.readText(path: binary.path); XCTFail("Binary preview succeeded") } catch {}
        do { _ = try await service.readText(path: large.path); XCTFail("Large preview succeeded") } catch {}
    }

    func testSavePreservesInodeAndDetectsExternalChanges() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("text")
        try Data("original".utf8).write(to: file)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let service = FileAccessManager(backupRoot: directory.appendingPathComponent("Backups"))
        let receipt = try await commit(.saveText(path: file.path, text: "短い", original: "original"), using: service)
        XCTAssertEqual(try String(contentsOf: receipt.backupDirectory.appendingPathComponent("original"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "短い")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
        do { _ = try await commit(.saveText(path: file.path, text: "overwrite", original: "original"), using: service); XCTFail("External edit was overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "短い")
    }

    func testScannerLimitsAndCancellation() async throws {
        let scanner = PathScanner()
        do { _ = try await scanner.scan(path: "/", maximum: 0) { _, _ in }; XCTFail("Zero limit accepted") } catch {}
        do { _ = try await scanner.scan(path: "/", maximum: 100_000_001) { _, _ in }; XCTFail("Excessive limit accepted") } catch {}
        let task = Task { try await scanner.scan(path: "/", maximum: 100_000_000) { _, _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TaiKueriRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func commit(_ operation: FileWriteOperation, using manager: FileAccessManager) async throws -> FileWriteReceipt {
        let request = try await manager.prepareWrite(operation)
        return try await manager.commitWrite(request, userConsented: true)
    }
}
