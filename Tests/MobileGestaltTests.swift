import XCTest
@testable import RunnerCore

final class MobileGestaltTests: XCTestCase {
    private let productType = "h9jDsbgj7xIVeIQ8S3/X3Q"

    func testBinaryAndXMLRoundTripPreserveKeysAndTypes() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let bytes = try fixture(format: format)
            var document = try MobileGestaltDocument(path: "/fixture.plist", data: bytes)
            XCTAssertEqual(try document.encoded(), bytes, "No-op must return the exact source bytes")
            try document.set(.string("TestPhone"), at: [.key("CacheExtra"), .key(productType)])
            XCTAssertEqual(document.changes.count, 1)
            let encoded = try document.encoded()
            let decoded = try PropertyListValue.decode(encoded)
            XCTAssertEqual(decoded.format, format)
            let updated = try MobileGestaltDocument(path: document.path, data: encoded)
            XCTAssertEqual(try updated.value(at: [.key("CacheExtra"), .key(productType)]), .string("TestPhone"))
            XCTAssertEqual(try updated.value(at: [.key("CacheExtra"), .key("boolean")]), .boolean(true))
            XCTAssertEqual(try updated.value(at: [.key("CacheExtra"), .key("integer")]), .integer("42"))
            XCTAssertEqual(try updated.value(at: [.key("CacheData")]), .data(Data([0, 1, 0xff])))
            XCTAssertFalse(try updated.entries(at: [.key("CacheExtra")]).contains { $0.key == "ProductType" })
        }
    }

    func testTypeChangeMissingKeyAndOversizedDraftAreRejectedWithoutChangingDocument() throws {
        var document = try MobileGestaltDocument(path: "/fixture.plist", data: fixture())
        let original = document.root
        XCTAssertThrowsError(try document.set(.string("true"), at: [.key("CacheExtra"), .key("boolean")]))
        XCTAssertThrowsError(try document.set(.string("new"), at: [.key("missing")]))
        XCTAssertThrowsError(try document.set(.dictionary([:]), at: [.key("CacheExtra")]))
        XCTAssertThrowsError(try document.set(.string(String(repeating: "x", count: 1_048_577)), at: [.key("CacheExtra"), .key(productType)]))
        XCTAssertEqual(document.root, original)
        XCTAssertTrue(document.changes.isEmpty)
    }

    func testScalarValidationAndUnsignedIntegers() throws {
        XCTAssertEqual(try PlistScalarEditor.parse("18446744073709551615", like: .integer("0")), .integer("18446744073709551615"))
        XCTAssertThrowsError(try PlistScalarEditor.parse("18446744073709551616", like: .integer("0")))
        XCTAssertThrowsError(try PlistScalarEditor.parse("1.5", like: .integer("0")))
        XCTAssertThrowsError(try PlistScalarEditor.parse("nan", like: .real(0)))
        XCTAssertThrowsError(try PlistScalarEditor.parse("inf", like: .real(0)))
        XCTAssertEqual(try PlistScalarEditor.parse("  value\n", like: .string("")), .string("  value\n"))
        let date = PropertyListValue.date(Date(timeIntervalSince1970: 0.125))
        XCTAssertEqual(try PlistScalarEditor.parse(PlistScalarEditor.input(for: date), like: date), date)
        XCTAssertThrowsError(try PlistScalarEditor.parse("invalid", like: date))
        let max = PropertyListValue.dictionary(["max": .integer("18446744073709551615")])
        XCTAssertEqual(try PropertyListValue.decode(max.encode(format: .binary)).value, max)
    }

    @MainActor
    func testRefreshReadsSavedAndRestoredCopyWithoutLosingDraft() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("MobileGestalt-copy.plist")
        let original = try fixture()
        try original.write(to: file)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let model = MobileGestaltModel()
        await model.refresh { try await manager.readMobileGestalt(path: file.path) }
        let entry = try XCTUnwrap(model.document?.entries(at: [.key("CacheExtra")]).first { $0.key == "boolean" })
        try model.edit(.boolean(false), entry: entry)
        await model.refresh { XCTFail("Automatic refresh discarded the draft"); throw RunnerError("Unexpected read") }
        let document = try XCTUnwrap(model.document)
        XCTAssertEqual(document.changes.count, 1)
        let request = try await manager.prepareWrite(.savePropertyList(path: file.path, data: document.encoded(), original: original))
        let receipt = try await manager.commitWrite(request, userConsented: true)
        model.acceptSaved(try document.encoded())
        await model.refresh { try await manager.readMobileGestalt(path: XCTUnwrap(model.document?.path)) }
        let updated = try XCTUnwrap(model.document)
        XCTAssertEqual(updated.path, file.path)
        XCTAssertTrue(updated.changes.isEmpty)
        XCTAssertEqual(updated.format, .binary)
        XCTAssertEqual(try updated.value(at: [.key("CacheExtra"), .key("boolean")]), .boolean(false))
        XCTAssertEqual(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("original")), original)
        let restore = try await manager.prepareWrite(.restoreBackup(id: receipt.backupDirectory.lastPathComponent))
        _ = try await manager.commitWrite(restore, userConsented: true)
        await model.refresh { try await manager.readMobileGestalt(path: XCTUnwrap(model.document?.path)) }
        XCTAssertEqual(try model.document?.value(at: entry.path), .boolean(true))
        XCTAssertEqual(model.document?.original, original)
    }

    @MainActor
    func testRefreshAvoidsDuplicateReadsAndDiscardsCancelledResults() async throws {
        let model = MobileGestaltModel()
        let document = try MobileGestaltDocument(path: "/copy.plist", data: fixture())
        let started = expectation(description: "Read started")
        var continuation: CheckedContinuation<MobileGestaltDocument, Never>?
        let task = Task {
            await model.refresh {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.refresh { XCTFail("Duplicate read started"); return document }
        task.cancel()
        continuation?.resume(returning: document)
        await task.value
        XCTAssertNil(model.document)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
        await model.refresh { document }
        XCTAssertEqual(model.document?.path, document.path)
    }

    func testManagerRejectsExternalChangeAndFormatChange() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("MobileGestalt.plist")
        let bytes = try fixture()
        try bytes.write(to: file)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        var document = try await manager.readMobileGestalt(path: file.path)
        try document.set(.string("draft"), at: [.key("CacheExtra"), .key(productType)])
        let xml = try document.root.encode(format: .xml)
        let badFormat = try await manager.prepareWrite(.savePropertyList(path: file.path, data: xml, original: bytes))
        do { _ = try await manager.commitWrite(badFormat, userConsented: true); XCTFail("Changed plist format") } catch {}
        let edit = try await manager.prepareWrite(.savePropertyList(path: file.path, data: document.encoded(), original: bytes))
        try Data("external".utf8).write(to: file)
        do { _ = try await manager.commitWrite(edit, userConsented: true); XCTFail("External edit overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
    }

    func testAutoAddedKeysRequireConsentAndBackupAndCanBeRestored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("MobileGestalt.plist")
        let bytes = try fixture()
        try bytes.write(to: file)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        var document = try await manager.readMobileGestalt(path: file.path)
        let feature = MobileGestaltFeature.bootChime
        try feature.stage(choice: "on", in: &document)
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Staging must not write to the source")
        try MobileGestaltFeature.validateGuidedChanges(in: document)
        let denied = try await manager.prepareWrite(.savePropertyList(path: file.path, data: document.encoded(), original: bytes))
        do { _ = try await manager.commitWrite(denied, userConsented: false); XCTFail("Missing consent accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let request = try await manager.prepareWrite(.savePropertyList(path: file.path, data: document.encoded(), original: bytes))
        let receipt = try await manager.commitWrite(request, userConsented: true)
        XCTAssertEqual(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("original")), bytes)
        let saved = try await manager.readMobileGestalt(path: file.path)
        XCTAssertEqual(try saved.value(at: feature.fields[0].path), .integer("1"))
        XCTAssertEqual(try saved.value(at: [.key("CacheData")]), .data(Data([0, 1, 0xff])))
        let restore = try await manager.prepareWrite(.restoreBackup(id: receipt.backupDirectory.lastPathComponent))
        _ = try await manager.commitWrite(restore, userConsented: true)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor
    func testModelKeepsDraftOnLoadFailureAndAcceptsSavedBaseline() async throws {
        let document = try MobileGestaltDocument(path: "/fixture.plist", data: fixture())
        let model = MobileGestaltModel()
        await model.load { document }
        let entry = try XCTUnwrap(model.document?.entries(at: [.key("CacheExtra")]).first { $0.key == productType })
        try model.edit(.string("draft"), entry: entry)
        await model.load { throw RunnerError("Failed read") }
        XCTAssertEqual(model.document?.changes.count, 1)
        XCTAssertNotNil(model.errorMessage)
        let saved = try XCTUnwrap(model.document).encoded()
        model.acceptSaved(saved)
        XCTAssertTrue(model.document?.changes.isEmpty == true)
        XCTAssertEqual(try model.document?.value(at: entry.path), .string("draft"))
    }

    private func fixture(format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        let object: [String: Any] = ["CacheData": Data([0, 1, 0xff]), "CacheExtra": [productType: "iPhone99,1", "boolean": true,
                                   "integer": 42, "real": 1.5, "array": [1, 2]] as [String: Any]]
        return try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileGestaltTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
