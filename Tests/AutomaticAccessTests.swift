import XCTest
@testable import RunnerCore

final class AutomaticAccessTests: XCTestCase {
    func testReadReleasesHandleZeroImmediatelyAndCanReacquire() async throws {
        let root = try fixture(bytes: Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let events = AccessEvents(), file = root.appendingPathComponent("file")
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"), accessBackend: backend(file, events: events))
        for _ in 0..<2 {
            let text = try await manager.readText(path: file.path)
            XCTAssertEqual(text, "original")
            let grants = await manager.currentGrants()
            XCTAssertTrue(grants.isEmpty)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0)
        }
        XCTAssertEqual(events.values, ["acquire", "release:0", "acquire", "release:0"])
    }

    func testReadFailureStillReleasesGrant() async throws {
        let root = try fixture(bytes: Data([0, 0xff]))
        defer { try? FileManager.default.removeItem(at: root) }
        let events = AccessEvents(), file = root.appendingPathComponent("file")
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"), accessBackend: backend(file, events: events))
        do { _ = try await manager.readText(path: file.path); XCTFail("Binary read as text") } catch {}
        XCTAssertEqual(events.values, ["acquire", "release:0"])
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    func testNestedReadKeepsPermissionThroughBackupAndWrite() async throws {
        let root = try fixture(bytes: Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let events = AccessEvents(), file = root.appendingPathComponent("file")
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"), accessBackend: backend(file, events: events))
        let request = try await manager.prepareWrite(.saveText(path: file.path, text: "changed", original: "original"))
        _ = try await manager.commitWrite(request, userConsented: true)
        XCTAssertEqual(events.values, ["acquire", "release:0"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    func testBackupFailureAlsoReleasesGrantAndResetInvalidatesConfirmation() async throws {
        let root = try fixture(bytes: Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let events = AccessEvents()
        let manager = FileAccessManager(backupRoot: blocker.appendingPathComponent("Backups"), accessBackend: backend(file, events: events))
        let request = try await manager.prepareWrite(.saveText(path: file.path, text: "changed", original: "original"))
        do { _ = try await manager.commitWrite(request, userConsented: true); XCTFail("Backup failed open") } catch {}
        XCTAssertEqual(events.values, ["acquire", "release:0"])
        let pending = try await manager.prepareWrite(.delete(path: file.path))
        await manager.releaseAll()
        do { _ = try await manager.commitWrite(pending, userConsented: true); XCTFail("Reset left a live confirmation") } catch {}
    }

    func testReadableButNotWritableFileAcquiresBeforeSavingAndReleasesAfterward() async throws {
        let root = try fixture(bytes: Data("original".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), events = AccessEvents()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"), accessBackend: backend(file, events: events))
        let text = try await manager.readText(path: file.path)
        XCTAssertEqual(text, "original")
        XCTAssertTrue(events.values.isEmpty)
        let request = try await manager.prepareWrite(.saveText(path: file.path, text: "changed", original: "original"))
        _ = try await manager.commitWrite(request, userConsented: true)
        XCTAssertEqual(events.values, ["acquire", "release:0"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed")
    }

    private func fixture(bytes: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticAccessTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("file")
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        return root
    }

    private func backend(_ file: URL, events: AccessEvents) -> SandboxAccessBackend {
        SandboxAccessBackend(acquire: { _ in
            events.append("acquire")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return 0
        }, release: { handle in
            events.append("release:\(handle)")
            try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        })
    }
}

private final class AccessEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
