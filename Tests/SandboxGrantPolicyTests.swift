import XCTest
@testable import RunnerCore

final class SandboxGrantPolicyTests: XCTestCase {
    func testZeroHandleIsValidWithoutFallback() throws {
        var flags: [Bool] = []
        let result = try SandboxGrantPolicy.acquire(preferAlternate: false, query: {
            flags.append($0); return 0
        }, sandboxAllowsOpen: { true }, release: { _ in XCTFail("Working handle was released") })
        XCTAssertEqual(result.handle, 0)
        XCTAssertFalse(result.alternateFlags)
        XCTAssertEqual(flags, [false])
    }

    func testUnusableTokenIsReleasedBeforeOtherFlagsAreTried() throws {
        var flags: [Bool] = [], released: [Int64] = [], probes = 0
        let result = try SandboxGrantPolicy.acquire(preferAlternate: false, query: {
            flags.append($0); return $0 ? 9 : 0
        }, sandboxAllowsOpen: { probes += 1; return probes == 2 }, release: { released.append($0) })
        XCTAssertEqual(flags, [false, true])
        XCTAssertEqual(released, [0])
        XCTAssertEqual(result.handle, 9)
        XCTAssertTrue(result.alternateFlags)
    }

    func testRejectedQueryTriesOtherFlagsExactlyOnce() throws {
        var flags: [Bool] = [], probes = 0
        let result = try SandboxGrantPolicy.acquire(preferAlternate: true, query: {
            flags.append($0); return $0 ? -5 : 12
        }, sandboxAllowsOpen: { probes += 1; return true }, release: { _ in XCTFail("Unexpected release") })
        XCTAssertEqual(flags, [true, false])
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(result.handle, 12)
        XCTAssertFalse(result.alternateFlags)
    }

    func testSigningAndAPIErrorsDoNotRetry() {
        for code: Int64 in [-1, -2] {
            var flags: [Bool] = []
            XCTAssertThrowsError(try SandboxGrantPolicy.acquire(preferAlternate: false, query: {
                flags.append($0); return code
            }, sandboxAllowsOpen: { XCTFail("Unexpected probe"); return false }, release: { _ in XCTFail("Unexpected release") }))
            XCTAssertEqual(flags, [false])
        }
    }

    func testBothUnusableTokensAreReleasedAndFailureIsReported() {
        var released: [Int64] = []
        XCTAssertThrowsError(try SandboxGrantPolicy.acquire(preferAlternate: false, query: { $0 ? 1 : 0 },
                                                          sandboxAllowsOpen: { false }, release: { released.append($0) })) { error in
            XCTAssertTrue(error.localizedDescription.contains("worse_query -8"))
        }
        XCTAssertEqual(released, [0, 1])
    }

    func testBothRejectedQueriesDoNotReleaseInvalidHandles() {
        var count = 0
        XCTAssertThrowsError(try SandboxGrantPolicy.acquire(preferAlternate: false, query: {
            count += 1; return $0 ? -6 : -5
        }, sandboxAllowsOpen: { XCTFail("Unexpected probe"); return false }, release: { _ in XCTFail("Invalid handle released") })) { error in
            XCTAssertTrue(error.localizedDescription.contains("worse_query -6"))
        }
        XCTAssertEqual(count, 2)
    }
}
