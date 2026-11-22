import XCTest
import Darwin
@testable import RunnerCore

final class ApplicationDataExportTests: XCTestCase {
    func testExportPreservesContentsIncludingHiddenFilesAndDoesNotTouchSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Container", isDirectory: true)
        let documents = source.appendingPathComponent("Documents", isDirectory: true)
        let library = source.appendingPathComponent("Library/Preferences", isDirectory: true)
        for directory in [documents, library, source.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let bytes = Data([0, 1, 0xff, 42])
        try bytes.write(to: documents.appendingPathComponent("こんにちは.txt"))
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try Data("preferences".utf8).write(to: library.appendingPathComponent("app.plist"))
        try Data("private temporary data".utf8).write(to: source.appendingPathComponent("tmp/excluded"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Library/Empty"), withIntermediateDirectories: false)
        let before = try FileBackupStore(root: root.appendingPathComponent("unused")).snapshot(source)
        let payload = root.appendingPathComponent("Data")
        try ApplicationDataExport.copy(source: source, to: payload)
        XCTAssertEqual(try Data(contentsOf: payload.appendingPathComponent("Documents/こんにちは.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: payload.appendingPathComponent(".hidden")), Data("hidden".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.appendingPathComponent("tmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.appendingPathComponent("Library/Empty").path))

        let archive = root.appendingPathComponent("data.zip")
        try ApplicationDataExport.archive(directory: payload, to: archive)
        XCTAssertEqual(try Data(contentsOf: archive).prefix(2), Data("PK".utf8))
        let extracted = root.appendingPathComponent("Extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Data/Documents/こんにちは.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("Data/.hidden")), Data("hidden".utf8))
        XCTAssertEqual(try FileBackupStore(root: root.appendingPathComponent("unused")).snapshot(source), before)
    }

    func testLinksSpecialFilesAndExistingDestinationsAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let outside = root.appendingPathComponent("outside")
        try Data("secret".utf8).write(to: outside)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("LinkedCopy")))
        XCTAssertEqual(try Data(contentsOf: outside), Data("secret".utf8))
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: link, to: root.appendingPathComponent("RootLink")))
        try FileManager.default.removeItem(at: link)
        let fifo = source.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("FifoCopy")))
        try FileManager.default.removeItem(at: fifo)
        let destination = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("keep"))
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("keep")), Data("keep".utf8))
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: source.appendingPathComponent("Recursive")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Recursive").path))
    }

    func testBoundsAndCancellationDoNotModifySource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 65, count: 32).write(to: source.appendingPathComponent("file"))
        for (index, limits) in [ApplicationDataExport.Limits(maximumBytes: 16), .init(maximumItems: 1), .init(maximumDepth: 0)].enumerated() {
            XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("Limited\(index)"), limits: limits))
        }
        let output = root.appendingPathComponent("Cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ApplicationDataExport.copy(source: source, to: output)
        }
        do { try await task.value; XCTFail("Cancelled export succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("file")), Data(repeating: 65, count: 32))
    }

    func testOwnWorkspaceInExcludedTmpDoesNotRecurse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("tmp/Export")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: root.appendingPathComponent("file"))
        let destination = workspace.appendingPathComponent("Data")
        try ApplicationDataExport.copy(source: root, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), Data("data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("tmp").path))
    }

    func testExportManagerRejectsPathsOutsideTheSelectedApp() async throws {
        let container = LaunchServicesPaths.applicationRoot + "/" + UUID().uuidString
        let app = CatalogApplication(bundleID: "example.app", name: "Example", kind: .application, containerPaths: [container], bundlePath: nil)
        let manager = FileAccessManager()
        for path in ["/", "/tmp", container + "/Documents", LaunchServicesPaths.applicationRoot + "/" + UUID().uuidString] {
            do { _ = try await manager.stageApplicationDataExport(application: app, path: path); XCTFail("Unexpected path accepted") } catch {}
        }
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
        let name = ApplicationDataExport.archiveFilename(bundleID: "../../bad/id\0")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\0"))
        XCTAssertTrue(name.hasSuffix(".zip"))
    }

    func testAppGroupExportRejectsPathsOutsideTheSelectedContainer() async throws {
        let container = AppGroupPaths.root + "/" + UUID().uuidString
        let group = AppGroupContainer(path: container, groupID: "group.example.app", canOpen: true, issues: [])
        let manager = FileAccessManager()
        let otherGroup = AppGroupPaths.root + "/" + UUID().uuidString
        for path in ["/", "/tmp", AppGroupPaths.root, container + "/Library", otherGroup,
                     LaunchServicesPaths.applicationRoot + "/" + UUID().uuidString] {
            do {
                _ = try await manager.stageAppGroupDataExport(group: group, path: path)
                XCTFail("Unexpected path accepted: \(path)")
            } catch {}
        }
        // The /private/var alias of the same container passes authorization and
        // fails only because that directory does not exist on the test host.
        do {
            _ = try await manager.stageAppGroupDataExport(group: group, path: "/private" + container)
            XCTFail("Unexpected success for a missing container")
        } catch let failure as ApplicationDataExport.Failure {
            XCTAssertEqual(failure.phase, "元データのコピー")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let unreadable = AppGroupContainer(path: container, groupID: nil, canOpen: false, issues: [])
        do {
            _ = try await manager.stageAppGroupDataExport(group: unreadable, path: container)
            XCTFail("Unreadable group accepted")
        } catch {}
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
        let name = ApplicationDataExport.archiveFilename(identifier: "../../bad/id\0")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains("\0"))
        XCTAssertTrue(name.hasSuffix("-data.zip"))
    }

    func testEverySourceOperationUsesScopedAccessAndFailureIdentifiesTheChild() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Container")
        let documents = source.appendingPathComponent("Documents")
        let file = documents.appendingPathComponent("private.txt")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("private data".utf8).write(to: file)
        var paths = Set<String>(), directories = Set<String>()
        let copy = root.appendingPathComponent("Copy")
        try ApplicationDataExport.copy(source: source, to: copy) { path, directory, operation in
            paths.insert(path)
            if directory { directories.insert(path) }
            try operation()
        }
        XCTAssertTrue(paths.contains(file.path))
        XCTAssertTrue(directories.contains(documents.path))
        XCTAssertTrue(paths.allSatisfy { $0 == source.path || $0.hasPrefix(source.path + "/") })
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("Documents/private.txt")), Data("private data".utf8))

        do {
            try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("Denied"), skipUnreadable: false) { path, _, operation in
                if path == file.path { throw POSIXError(.EACCES) }
                try operation()
            }
            XCTFail("Denied child was silently skipped")
        } catch let error as ApplicationDataExport.SourceReadFailure {
            XCTAssertEqual(error.path, file.path)
            XCTAssertEqual((error.underlying as? POSIXError)?.code, .EACCES)
            XCTAssertTrue(error.localizedDescription.contains(file.path))
        }
    }

    func testCopySessionRetainsAndReleasesPermissionsOnSuccessAndFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Container")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("data".utf8).write(to: source.appendingPathComponent("file"))
        let events = ExportAccessEvents()
        let backend = SandboxAccessBackend(acquire: { path in
            events.append("acquire:" + path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
            return 0
        }, release: { handle in
            events.append("release:\(handle)")
            try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        })
        let manager = FileAccessManager(accessBackend: backend)
        for failing in [false, true] {
            if failing {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
                try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: source.appendingPathComponent("file"))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
            let destination = root.appendingPathComponent(failing ? "Failed" : "Copy")
            do {
                try await manager.copyApplicationData(path: source.path, to: destination)
                if failing { XCTFail("Link was accepted") }
                else { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), Data("data".utf8)) }
            } catch { if !failing { XCTFail("\(error)") } }
            let grants = await manager.currentGrants()
            XCTAssertTrue(grants.isEmpty)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue, 0)
        }
        XCTAssertEqual(events.values, ["acquire:" + source.path, "release:0", "acquire:" + source.path, "release:0"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    }

    func testProtectedContainerMetadataIsNotReadButOtherHiddenDataIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("PosterBoard")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let metadata = source.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        try Data("OS managed".utf8).write(to: metadata)
        try Data("app data".utf8).write(to: source.appendingPathComponent(".hidden"))
        let destination = root.appendingPathComponent("Data")
        var metadataRequested = false
        try ApplicationDataExport.copy(source: source, to: destination) { path, _, operation in
            if path == metadata.path {
                metadataRequested = true
                throw POSIXError(.EPERM)
            }
            try operation()
        }
        XCTAssertFalse(metadataRequested)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(metadata.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".hidden")), Data("app data".utf8))
        XCTAssertEqual(try Data(contentsOf: metadata), Data("OS managed".utf8))
    }

    func testInProcessZIPCRCEmptyEntriesAndFailureCleanup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("EmptyFolder"), withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("empty"))
        try Data("123456789".utf8).write(to: source.appendingPathComponent("vector"))
        let archive = root.appendingPathComponent("stored.zip")
        try ApplicationDataExport.archive(directory: source, to: archive)
        let data = try Data(contentsOf: archive)
        // ZIP data descriptor followed by the standard CRC-32 test vector.
        XCTAssertNotNil(data.range(of: Data([0x50, 0x4b, 0x07, 0x08, 0x26, 0x39, 0xf4, 0xcb])))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let limited = root.appendingPathComponent("limited.zip")
        XCTAssertThrowsError(try StoredZIPArchive.write(directory: source, to: limited, maximumBytes: 32))
        XCTAssertFalse(FileManager.default.fileExists(atPath: limited.path))
        let existing = root.appendingPathComponent("existing.zip")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try ApplicationDataExport.archive(directory: source, to: existing))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))

        // Avoid cross-platform ZIP path traversal via backslash file names.
        try Data("unsafe".utf8).write(to: source.appendingPathComponent("..\\outside"))
        let unsafe = root.appendingPathComponent("unsafe.zip")
        XCTAssertThrowsError(try ApplicationDataExport.archive(directory: source, to: unsafe))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.path))
    }

    func testExportFailureAlwaysIncludesPhaseAndPOSIXCode() {
        let error = ApplicationDataExport.Failure(phase: "作業フォルダの作成", underlying: POSIXError(.EPERM))
        XCTAssertTrue(error.localizedDescription.contains("作業フォルダの作成"))
        XCTAssertTrue(error.localizedDescription.contains("NSPOSIXErrorDomain (1)"))
        let read = ApplicationDataExport.SourceReadFailure(path: "/container/Library/data", operation: "ファイル内容の読み取り", underlying: POSIXError(.EPERM))
        let failure = ApplicationDataExport.Failure(phase: "元データのコピー", underlying: read)
        XCTAssertTrue(failure.localizedDescription.contains("ファイル内容の読み取り"))
        XCTAssertTrue(failure.localizedDescription.contains(read.path))
        XCTAssertTrue(failure.localizedDescription.contains("NSPOSIXErrorDomain (1)"))
    }

    func testStoredZIPCancellationAndEmptyContainer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Data")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("empty.zip")
        try ApplicationDataExport.archive(directory: source, to: archive)
        let output = root.appendingPathComponent("cancelled.zip")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ApplicationDataExport.archive(directory: source, to: output)
        }
        do { try await task.value; XCTFail("Cancelled ZIP succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testUnreadableItemsAreOmittedAndPartialFilesAreRemovedWithReportInZIP() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Locked"), withIntermediateDirectories: true)
        try Data("good".utf8).write(to: source.appendingPathComponent("good"))
        try Data("app report".utf8).write(to: source.appendingPathComponent("ExportReport.json"))
        try Data("secret".utf8).write(to: source.appendingPathComponent("Locked/secret"))
        try Data(repeating: 65, count: 2 * 1_048_576).write(to: source.appendingPathComponent("mid-read"))
        let destination = root.appendingPathComponent("Data")
        let report = try ApplicationDataExport.copy(source: source, to: destination) { path, _, operation in
            if path == source.appendingPathComponent("Locked").path { throw POSIXError(.EACCES) }
            if path == source.appendingPathComponent("mid-read").path,
               let attributes = try? FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("mid-read").path),
               (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 { throw POSIXError(.EPERM) }
            try operation()
        }
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.copiedFileCount, 2)
        XCTAssertEqual(report.copiedBytes, 14)
        XCTAssertEqual(Set(report.skippedItems.map(\.path)), ["Locked", "mid-read"])
        XCTAssertEqual(Set(report.skippedItems.map(\.errorCode)), [Int(EACCES), Int(EPERM)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("mid-read").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Locked").path))
        let archive = root.appendingPathComponent("partial.zip")
        try ApplicationDataExport.archive(directory: destination, to: archive, report: report.encoded())
        let decoded = try JSONDecoder().decode(ApplicationDataExport.Report.self, from: extract("ExportReport.json", from: archive))
        XCTAssertEqual(decoded.skippedItems.map(\.path), report.skippedItems.map(\.path))
        XCTAssertEqual(decoded.copiedBytes, report.copiedBytes)
        XCTAssertEqual(try extract("Data/ExportReport.json", from: archive), Data("app report".utf8))
        XCTAssertEqual(try extract("Data/good", from: archive), Data("good".utf8))
    }

    func testLateDirectoryDenialRemovesItsCopiedSubtreeAndUpdatesCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        let tree = source.appendingPathComponent("Tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("copied then discarded".utf8).write(to: tree.appendingPathComponent("file"))
        try Data("keep".utf8).write(to: source.appendingPathComponent("good"))
        let destination = root.appendingPathComponent("Data")
        let report = try ApplicationDataExport.copy(source: source, to: destination) { path, _, operation in
            if path == tree.path && FileManager.default.fileExists(atPath: destination.appendingPathComponent("Tree/file").path) {
                throw POSIXError(.EACCES)
            }
            try operation()
        }
        XCTAssertEqual(report.skippedItems.map(\.path), ["Tree"])
        XCTAssertEqual(report.copiedFileCount, 1)
        XCTAssertEqual(report.copiedBytes, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Tree").path))
    }

    func testChangedDataAndOutputDenialStillFailInsteadOfBeingOmitted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("file")
        try Data("original".utf8).write(to: file)
        let destination = root.appendingPathComponent("Data")
        var changed = false
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: destination) { path, _, operation in
            if path == source.path && !changed && FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path) {
                try Data("modified".utf8).write(to: file)
                changed = true
            }
            try operation()
        })
        XCTAssertTrue(changed)
        let blocked = root.appendingPathComponent("Blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: blocked.appendingPathComponent("Copy")))
    }

    func testLargerLimitsReachBothCopyAndZIPInventoryWithoutRelaxingBackups() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let large = source.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        XCTAssertEqual(try StoredZIPArchive.inventory(source)["./large"]?.size, 256 * 1024 * 1024 + 1)
        try handle.truncate(atOffset: UInt64(ApplicationDataExport.Limits().maximumBytes) + 1)
        try handle.close()
        XCTAssertThrowsError(try StoredZIPArchive.inventory(source))
        XCTAssertThrowsError(try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("TooLarge")))
        try FileManager.default.removeItem(at: large)
        var deep = source
        for _ in 0..<66 {
            deep.appendPathComponent("n")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: false)
        }
        try Data("deep".utf8).write(to: deep.appendingPathComponent("file"))
        let report = try ApplicationDataExport.copy(source: source, to: root.appendingPathComponent("DeepCopy"))
        XCTAssertEqual(report.copiedFileCount, 1)
        XCTAssertEqual(try StoredZIPArchive.inventory(source).count, 68)
        XCTAssertEqual(FileBackupStore.maximumBytes, 256 * 1024 * 1024)
        XCTAssertEqual(FileBackupStore.maximumItems, 10_000)
    }

    func testFailedGrantStillAllowsAnUnreadableChildToBeReportedAndSkipped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: source.appendingPathComponent("good"))
        let blocked = source.appendingPathComponent("blocked")
        try Data("private".utf8).write(to: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let events = ExportAccessEvents()
        let manager = FileAccessManager(accessBackend: SandboxAccessBackend(acquire: { path in
            events.append(path)
            throw RunnerError("test grant rejected")
        }, release: { _ in events.append("unexpected release") }))
        let destination = root.appendingPathComponent("Data")
        let report = try await manager.copyApplicationData(path: source.path, to: destination)
        XCTAssertEqual(report.skippedItems.map(\.path), ["blocked"])
        XCTAssertEqual(report.skippedItems.first?.errorCode, Int(EACCES))
        XCTAssertTrue(report.skippedItems.first?.reason.contains("test grant rejected") == true)
        XCTAssertEqual(report.copiedFileCount, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("good")), Data("keep".utf8))
        XCTAssertFalse(events.values.contains("unexpected release"))
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    func testZIPInventoryAcceptsMoreThanTheOldTenThousandItemLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10_001 {
            XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent("\(index)").path, contents: nil))
        }
        XCTAssertEqual(try StoredZIPArchive.inventory(root).count, 10_002)
    }

    private func extract(_ name: String, from archive: URL) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationDataExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class ExportAccessEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
