import XCTest
@testable import RunnerCore

final class RespringTests: XCTestCase {
    func testStopIsTerminal() {
        var state = RespringAttemptState()
        XCTAssertTrue(state.receive(.started))
        XCTAssertTrue(state.receive(.stopped(.user)))
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.receive(.started))
        XCTAssertFalse(state.receive(.stopped(.timeout)))
        XCTAssertEqual(state.stopReason, .user)
    }
}
