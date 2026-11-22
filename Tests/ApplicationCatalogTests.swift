import XCTest
import Darwin
@testable import RunnerCore

final class ApplicationCatalogTests: XCTestCase {
    func testAllKnownLayoutsRecoverAppsAndExtensions() throws {
        for layout in CSStoreParser.layouts {
            let result = try CSStoreParser.parse(store(layout: layout))
            XCTAssertEqual(result.layout, layout.name)
            XCTAssertEqual(result.applications.count, 2)
            let app = try XCTUnwrap(result.applications.first { $0.kind == .application })
            XCTAssertEqual(app.bundleID, "com.example.reader")
            XCTAssertEqual(app.name, "Reader 日本")
            XCTAssertEqual(app.containerPaths, [appPath])
            XCTAssertEqual(app.bundlePath, "/Applications/Reader.app")
            let plugin = try XCTUnwrap(result.applications.first { $0.kind == .appExtension })
            XCTAssertEqual(plugin.bundleID, "com.example.reader.widget")
            XCTAssertEqual(plugin.containerPaths, [pluginPath])
            XCTAssertEqual(result.sharedGroupPaths, [groupPath])
        }
    }

    func testIOS26OverlappingStringTablesAndTrailingSlash() throws {
        let layout = CSStoreParser.layouts[1]
        var data = store(layout: layout)
        putString(&data, at: 0x800, id: 2, value: "/private" + appPath + "/")
        putString(&data, at: 0x1300, id: 2, value: "Not a container string")
        let result = try CSStoreParser.parse(data)
        XCTAssertEqual(result.applications.first { $0.kind == .application }?.containerPaths, [appPath])
    }

    func testConflictingContainerClaimsAreNotGuessed() throws {
        var data = store()
        let layout = CSStoreParser.layouts[0]
        put32(&data, at: 0xa04, value: UInt32(layout.size))
        put32(&data, at: 0xa08 + layout.bundleID, value: 9 << 2)
        put32(&data, at: 0xa08 + layout.container, value: 2 << 2)
        putString(&data, at: 0x2300, id: 9, value: "com.example.conflict")
        let result = try CSStoreParser.parse(data)
        XCTAssertFalse(result.applications.contains { $0.kind == .application })
        XCTAssertEqual(result.ambiguousContainerCount, 1)
        XCTAssertEqual(result.applications.count, 1)
    }

    func testAmbiguousPathStringIDIsExcluded() throws {
        var data = store()
        putString(&data, at: 0x2300, id: 2, value: appPath.replacingOccurrences(of: "11111111", with: "99999999"))
        let result = try CSStoreParser.parse(data)
        XCTAssertFalse(result.applications.contains { $0.kind == .application })
        XCTAssertGreaterThan(result.ambiguousContainerCount, 0)
    }

    func testMalformedStringsReferencesAndMagicFailClosed() throws {
        var badMagic = store()
        badMagic[0] = 0
        XCTAssertThrowsError(try CSStoreParser.parse(badMagic))
        XCTAssertThrowsError(try CSStoreParser.parse(Data("bdsl".utf8)))
        var data = store()
        put32(&data, at: 0x208 + 0x0c, value: 7) // Not an aligned string reference.
        let result = try CSStoreParser.parse(data)
        XCTAssertTrue(result.applications.allSatisfy { $0.kind == .appExtension })
        put32(&data, at: 0x608, value: 0xffff_ffff)
        XCTAssertThrowsError(try CSStoreParser.parse(data))
        var truncated = store()
        put32(&truncated, at: 0x1704, value: UInt32.max)
        let fallback = try CSStoreParser.parse(truncated)
        XCTAssertEqual(fallback.applications.first { $0.kind == .application }?.name, "Reader")
    }

    func testUnterminatedFourByteStringsAndDataSlices() throws {
        var data = store()
        putString(&data, at: 0x1700, id: 4, value: "Name1234")
        data[0x1710] = 0x30 // Multiple-of-four strings need no NUL terminator.
        let result = try CSStoreParser.parse(data)
        XCTAssertEqual(result.applications.first { $0.kind == .application }?.name, "Name1234")
        let wrapped = Data(repeating: 0xee, count: 17) + data
        XCTAssertEqual(try CSStoreParser.parse(wrapped.dropFirst(17)).applications.count, 2)
    }

    func testRecordAtEndAndNamesAreBoundedAndSanitized() throws {
        var data = store()
        let record = data[0x200..<(0x208 + 0x250)]
        data.replaceSubrange(0x200..<(0x208 + 0x250), with: Data(repeating: 0, count: record.count))
        data.replaceSubrange((data.count - record.count)..<data.count, with: record)
        putString(&data, at: 0x1700, id: 4, value: "Cafe\u{301} 日本 \u{202e}evil")
        let result = try CSStoreParser.parse(data)
        XCTAssertEqual(result.applications.first { $0.kind == .application }?.name, "Café 日本 �evil")
        XCTAssertNil(CSStoreParser.safeName("/private/path"))
        XCTAssertNil(CSStoreParser.safeName("name\u{0001}bad"))
        XCTAssertFalse(CSStoreParser.validBundleID("com.example/invalid"))
    }

    func testContainerAndStorePathsCannotEscapeTheirRoot() {
        let root = LaunchServicesPaths.applicationRoot
        XCTAssertEqual(LaunchServicesPaths.container("/private" + appPath + "/", root: root), appPath)
        for path in [appPath + "/Library", root + "/../" + uuid, root + "//" + uuid, root + "/not-a-uuid", "/other/" + uuid] {
            XCTAssertNil(LaunchServicesPaths.container(path, root: root))
        }
        let storePath = LaunchServicesPaths.daemonRoot + "/" + uuid + "/Library/Caches/com.apple.LaunchServices-v2.csstore"
        XCTAssertEqual(LaunchServicesPaths.daemonContainer(forStore: storePath), LaunchServicesPaths.daemonRoot + "/" + uuid)
        XCTAssertEqual(LaunchServicesPaths.accessTargets(forStore: "/private" + storePath), [URL(fileURLWithPath: storePath).deletingLastPathComponent().path, storePath])
        XCTAssertNil(LaunchServicesPaths.accessTargets(forStore: "/var/mobile/not-a-store"))
        XCTAssertNil(LaunchServicesPaths.daemonContainer(forStore: storePath.replacingOccurrences(of: "/Library/", with: "/Library/../Library/")))
        XCTAssertNil(LaunchServicesPaths.daemonContainer(forStore: storePath.replacingOccurrences(of: ".csstore", with: ".sqlite")))
        XCTAssertNil(LaunchServicesPaths.bundlePath("/Applications/../other/Bad.app"))
    }

    func testStableReaderRejectsLinksSpecialFilesOversizeAndMutation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("store")
        try store().write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try StableFileReader.read(path: link.path, maximumBytes: 65536, decode: CSStoreParser.parse))
        XCTAssertThrowsError(try StableFileReader.read(path: root.path, maximumBytes: 65536) { $0 })
        XCTAssertThrowsError(try StableFileReader.read(path: file.path, maximumBytes: 4) { $0 })
        XCTAssertThrowsError(try StableFileReader.read(path: file.path, maximumBytes: 65536) { data in
            try Data("changed".utf8).write(to: file)
            return data
        })
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try StableFileReader.read(path: fifo.path, maximumBytes: 65536) { $0 })
    }

    func testSyntheticStoreReadIsReadOnlyAndDeviceReaderRejectsArbitraryPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.csstore")
        let bytes = store()
        try bytes.write(to: file)
        let files = FileAccessManager()
        let parsed = try StableFileReader.read(path: file.path, maximumBytes: CSStoreParser.maximumBytes, decode: CSStoreParser.parse)
        XCTAssertEqual(parsed.applications.count, 2)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        do {
            _ = try await files.readLaunchServicesCatalog(path: file.path, group: "")
            XCTFail("Arbitrary file was treated as a device DB")
        } catch {}
    }

    func testEmbeddedGroupIdentifiersSurviveCatalogParser() throws {
        var data = store()
        let plist = try PropertyListSerialization.data(fromPropertyList: ["__NO_PERSONA__": ["group.example.shared": "/private" + groupPath + "/"]],
                                                       format: .binary, options: 0)
        data.append(plist)
        let parsed = try CSStoreParser.parse(data)
        XCTAssertEqual(parsed.sharedGroupIdentifiers, [groupPath: ["group.example.shared"]])
        XCTAssertEqual(parsed.sharedGroupPaths, [groupPath])
    }

    func testDiscoverySearchesBackwardAndSkipsInvalidCandidates() async throws {
        let calls = DiscoveryCalls()
        let valid = LaunchServicesPaths.daemonRoot + "/" + uuid + "/Library/Caches/com.apple.LaunchServices-v2.csstore"
        let finder = LaunchServicesStoreFinder(upperBound: { 4096 }, candidates: { first, last in
            calls.record(first, last)
            return last == 4096 ? ["/untrusted/com.apple.LaunchServices-v2.csstore"] : [valid]
        }, now: { 0 })
        let snapshot = ApplicationCatalogSnapshot(catalog: try CSStoreParser.parse(store()), sourcePath: valid, loadedAt: Date())
        let result = try await finder.find(accept: { path in path == valid ? snapshot : nil }, progress: { _ in })
        XCTAssertEqual(result.sourcePath, valid)
        XCTAssertEqual(calls.ranges.map { $0.0 }, [2049, 1])
        XCTAssertEqual(calls.ranges.map { $0.1 }, [4096, 2048])
    }

    func testDiscoveryCancellationAndUnavailableProbe() async throws {
        let finder = LaunchServicesStoreFinder(upperBound: { 0 }, candidates: { _, _ in XCTFail("Unexpected scan"); return [] })
        do { _ = try await finder.find(accept: { _ in nil }, progress: { _ in }); XCTFail("Missing probe accepted") } catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await finder.find(accept: { _ in nil }, progress: { _ in })
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testParserCancellation() async throws {
        let bytes = store()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CSStoreParser.parse(bytes)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private let uuid = "11111111-1111-4111-8111-111111111111"
    private var appPath: String { LaunchServicesPaths.applicationRoot + "/" + uuid }
    private var pluginPath: String { LaunchServicesPaths.extensionRoot + "/22222222-2222-4222-8222-222222222222" }
    private var groupPath: String { LaunchServicesPaths.groupRoot + "/33333333-3333-4333-8333-333333333333" }

    private func store(layout: CSStoreParser.Layout = CSStoreParser.layouts[0]) -> Data {
        var data = Data(repeating: 0, count: 0x6000)
        data.replaceSubrange(0..<4, with: Data("bdsl".utf8))
        data.replaceSubrange(0x1000..<0x1008, with: Data("<string>".utf8))
        put32(&data, at: 0x204, value: UInt32(layout.size))
        put32(&data, at: 0x208, value: 7 << 2)
        put32(&data, at: 0x208 + layout.bundleID, value: 1 << 2)
        put32(&data, at: 0x208 + layout.container, value: 2 << 2)
        put32(&data, at: 0x208 + layout.bundleName, value: 3 << 2)
        put32(&data, at: 0x208 + layout.displayName, value: 4 << 2)
        put32(&data, at: 0x604, value: UInt32(layout.pluginSize))
        put32(&data, at: 0x608 + layout.pluginID, value: 5 << 2)
        put32(&data, at: 0x608 + layout.pluginContainer, value: 6 << 2)
        let strings = ["com.example.reader", "/private" + appPath, "Reader", "Reader 日本", "com.example.reader.widget",
                       "/private" + pluginPath, "/Applications/Reader.app", "/private" + groupPath]
        for (index, value) in strings.enumerated() { putString(&data, at: 0x1100 + index * 0x200, id: UInt32(index + 1), value: value) }
        return data
    }

    private func put32(_ data: inout Data, at offset: Int, value: UInt32) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private func putString(_ data: inout Data, at offset: Int, id: UInt32, value: String) {
        let bytes = Data(value.utf8)
        put32(&data, at: offset, value: id)
        put32(&data, at: offset + 4, value: UInt32(bytes.count))
        data.replaceSubrange((offset + 8)..<(offset + 8 + bytes.count), with: bytes)
        data[offset + 8 + bytes.count] = bytes.count.isMultiple(of: 4) ? 0x30 : 0
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationCatalogTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class DiscoveryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(UInt64, UInt64)] = []
    var ranges: [(UInt64, UInt64)] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ first: UInt64, _ last: UInt64) { lock.lock(); defer { lock.unlock() }; values.append((first, last)) }
}
