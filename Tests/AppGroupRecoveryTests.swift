import XCTest
@testable import RunnerCore

final class AppGroupRecoveryTests: XCTestCase {
    private let path = AppGroupPaths.root + "/ABCDEFAB-1234-4234-8234-ABCDEFABCDEF"

    func testNestedEmbeddedPlistsAliasesArraysAndConflicts() throws {
        // Use the correct case-sensitive root, with only UUID case changed.
        var data = Data(repeating: 0xee, count: 31) + (try plist([
            "__NO_PERSONA__": [["group.example.shared": "/private" + AppGroupPaths.root + "/" + URL(fileURLWithPath: path).lastPathComponent.lowercased() + "/"],
                              ["group.example.shared": path],
                              ["bad/no": path, ".bad": path, "bad.": path, "notID": path, "group.bad\n": path]]
        ]))
        XCTAssertEqual(try CSStoreGroupIdentifiers.parse(data), [path: ["group.example.shared"]])
        data.append(try plist(["group.example.conflict": path]))
        XCTAssertEqual(try CSStoreGroupIdentifiers.parse(data)[path], ["group.example.shared", "group.example.conflict"])
        let wrapped = Data(repeating: 0, count: 19) + data
        XCTAssertEqual(try CSStoreGroupIdentifiers.parse(wrapped.dropFirst(19)), try CSStoreGroupIdentifiers.parse(data))
    }

    func testOnlyExactPathsAndBoundedPlistDepthAreAccepted() throws {
        let bad = try plist(["group.example.shared": path + "/Library", "group.other": "/elsewhere/" + URL(fileURLWithPath: path).lastPathComponent])
        XCTAssertTrue(try CSStoreGroupIdentifiers.parse(bad).isEmpty)
        var object: Any = ["group.example.shared": path]
        for _ in 0..<8 { object = ["nested": object] }
        XCTAssertTrue(try CSStoreGroupIdentifiers.parse(plist(object)).isEmpty)
        XCTAssertTrue(try CSStoreGroupIdentifiers.parse(Data(path.utf8)).isEmpty)
    }

    func testMalformedTruncatedAndOverflowTrailersAreIgnored() throws {
        let good = try plist(["group.example.shared": path])
        XCTAssertTrue(try CSStoreGroupIdentifiers.parse(good.dropLast(1)).isEmpty)
        for position in [6, 7, 8, 16, 24] {
            var bad = good
            let trailer = bad.count - 32
            bad[trailer + position] = 0xff
            XCTAssertTrue(try CSStoreGroupIdentifiers.parse(bad).isEmpty)
        }
        // Invalid plist is followed by a valid one; nearest header discovery must recover.
        let data = Data("bplist00 /mobile/Containers/Shared/AppGroup/not-a-uuid".utf8) + Data(repeating: 0, count: 50) + good
        XCTAssertEqual(try CSStoreGroupIdentifiers.parse(data), [path: ["group.example.shared"]])
    }

    func testTrailerShapedBytesInsidePlistRetryTheRealTrailer() throws {
        var bytes = try plist([["group.example.shared": path], Data(repeating: 0, count: 128)] as [Any])
        let padding = try XCTUnwrap(bytes.range(of: Data(repeating: 0, count: 128)))
        let trailer = padding.lowerBound + 16, length = trailer + 32
        bytes[trailer + 6] = 1
        bytes[trailer + 7] = 1
        bytes[trailer + 15] = 1 // object count = 1, top object = 0
        var table = UInt64(length - 33).bigEndian
        withUnsafeBytes(of: &table) { bytes.replaceSubrange((trailer + 24)..<(trailer + 32), with: $0) }
        XCTAssertEqual(try CSStoreGroupIdentifiers.parse(bytes), [path: ["group.example.shared"]])
    }

    func testRecoveryCancellation() async throws {
        let groupBytes = try plist(["group.example.shared": path])
        let groups = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CSStoreGroupIdentifiers.parse(groupBytes)
        }
        do { _ = try await groups.value; XCTFail("Ignored cancellation") } catch is CancellationError {}
    }

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
