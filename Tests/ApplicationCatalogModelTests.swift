import XCTest
@testable import RunnerCore

final class ApplicationCatalogModelTests: XCTestCase {
    @MainActor
    func testOutdatedResultAndProgressCannotReplaceCurrentCatalog() async {
        let model = ApplicationCatalogModel(), gate = CatalogGate()
        let started = expectation(description: "Old request started")
        let stale = snapshot("old"), current = snapshot("current")
        let old = Task {
            await model.load { progress in
                started.fulfill()
                await gate.wait()
                await progress("Outdated status")
                return stale
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.load { progress in
            await progress("Current status")
            return current
        }
        await gate.open()
        await old.value
        XCTAssertEqual(model.snapshot?.sourcePath, "current")
        XCTAssertEqual(model.status, "読み込み完了")
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCancellationDropsEvenSuccessfulLateResult() async {
        let model = ApplicationCatalogModel(), gate = CatalogGate()
        let started = expectation(description: "Load started")
        let result = snapshot("cancelled")
        let task = Task {
            await model.load { _ in
                started.fulfill()
                await gate.wait()
                return result
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.open()
        await task.value
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.status, "中止しました。")
        XCTAssertFalse(model.loading)
    }

    @MainActor
    func testFailedRefreshDoesNotLeaveAnApparentlyCurrentSnapshot() async {
        let model = ApplicationCatalogModel()
        let result = snapshot("initial")
        await model.load { _ in result }
        XCTAssertNotNil(model.snapshot)
        await model.load { _ in throw RunnerError("Changed database") }
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.errorMessage, "Changed database")
        XCTAssertFalse(model.loading)
    }

    private func snapshot(_ path: String) -> ApplicationCatalogSnapshot {
        ApplicationCatalogSnapshot(catalog: ParsedApplicationCatalog(layout: "test", applications: [], sharedGroupPaths: [], ambiguousContainerCount: 0),
                                   sourcePath: path, loadedAt: Date())
    }
}

private actor CatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
