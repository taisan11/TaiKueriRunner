import XCTest
@testable import RunnerCore

final class DocumentPreviewTests: XCTestCase {
    func testPlistDepthAndByteLimits() throws {
        XCTAssertThrowsError(try DocumentPreview.propertyList(Data(repeating: 65, count: DocumentPreview.maximumPlistBytes + 1)))
        var object: Any = "leaf"
        for _ in 0..<34 { object = [object] }
        let nested = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        XCTAssertThrowsError(try DocumentPreview.propertyList(nested))
        XCTAssertThrowsError(try DocumentPreview.propertyList(Data("not a plist".utf8)))
    }

    func testPlistTreePreservesTypesAndArrayIndices() throws {
        let object: [String: Any] = ["array": ["value", false, 12, 1.5], "data": Data([0, 0xff]), "date": Date(timeIntervalSince1970: 0), "empty": [String: String]()]
        let bytes = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        let root = try DocumentPreview.propertyList(bytes).root
        let children = try XCTUnwrap(root.children)
        let array = try XCTUnwrap(children.first { $0.key == "array" }?.children)
        XCTAssertEqual(array.map(\.key), ["[0]", "[1]", "[2]", "[3]"])
        XCTAssertEqual(array.map(\.type), ["String", "Boolean", "Integer", "Real"])
        XCTAssertEqual(Set(array.map(\.id)).count, array.count)
        XCTAssertEqual(children.first { $0.key == "data" }?.type, "Data")
        XCTAssertEqual(children.first { $0.key == "date" }?.type, "Date")
        XCTAssertEqual(children.first { $0.key == "empty" }?.children?.count, 0)
    }

    func testHexPreviewReadsOnlyPrefixOfLargeFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.bin")
        let bytes = Data(repeating: 0x41, count: 100_000)
        try bytes.write(to: source)
        let preview = try await FileAccessManager().readHexPreview(path: source.path)
        XCTAssertEqual(preview.totalBytes, 100_000)
        XCTAssertEqual(preview.shownBytes, 65_536)
        XCTAssertTrue(preview.text.hasPrefix("00000000  41 41"))
        XCTAssertEqual(preview.text.components(separatedBy: "\n").count, 4096)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(DocumentPreview.hexDump(Data()), "")
        XCTAssertTrue(DocumentPreview.hexDump(Data([0, 0x20, 0x7f])).hasSuffix(". ."))
    }

    func testSystemPreviewUsesPrivateCopyAndCleansOnlyOwnedDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sample.pdf")
        let bytes = Data("%PDF-1.4\nfixture".utf8)
        try bytes.write(to: source)
        let service = FileAccessManager()
        let staged = try await service.stageDocumentPreview(path: source.path)
        XCTAssertNotEqual(staged.url, source)
        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        try Data("changed local copy".utf8).write(to: staged.url)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let unowned = StagedDocumentPreview(url: source, directory: root)
        await service.closeDocumentPreview(unowned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await service.closeDocumentPreview(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await service.closeDocumentPreview(staged) // Idempotent.
    }

    func testSystemPreviewRejectsOversizedAndSymbolicFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(DocumentPreview.maximumMediaBytes + 1))
        try handle.close()
        let service = FileAccessManager()
        do { _ = try await service.stageDocumentPreview(path: source.path); XCTFail("Oversized preview succeeded") } catch {}
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        do { _ = try await service.stageDocumentPreview(path: link.path); XCTFail("Symbolic source opened") } catch {}
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentPreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
