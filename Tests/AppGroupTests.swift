import XCTest
@testable import RunnerCore

final class AppGroupTests: XCTestCase {
    func testPathsAcceptOnlyImmediateUUIDGroupContainersAndKnownVarAlias() {
        let id = UUID().uuidString
        let path = AppGroupPaths.root + "/" + id
        XCTAssertEqual(AppGroupPaths.container(path), path)
        XCTAssertEqual(AppGroupPaths.container("/private" + path), path)
        XCTAssertEqual(AppGroupPaths.child(id), path)
        for invalid in [AppGroupPaths.root, path + "/Library", AppGroupPaths.root + "/not-a-uuid",
                        "/var/mobile/Containers/Data/Application/" + id, "/etc/" + id,
                        AppGroupPaths.root + "-other/" + id] {
            XCTAssertNil(AppGroupPaths.container(invalid), invalid)
        }
        for name in ["../" + id, id + "/Library", "not-a-uuid", "", ".hidden"] { XCTAssertNil(AppGroupPaths.child(name)) }
    }

    func testMetadataReadsIdentifierFromBinaryAndXMLWithoutInferringMembers() throws {
        let id = UUID().uuidString, path = AppGroupPaths.root + "/" + id
        for format: PropertyListSerialization.PropertyListFormat in [.binary, .xml] {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "MCMMetadataIdentifier": "group.com.example.shared",
                "MCMMetadataUUID": id.lowercased(),
                "SomeUnverifiedOwner": "com.example.app"
            ], format: format, options: 0)
            XCTAssertEqual(try AppGroupPaths.identifier(from: data, container: path), "group.com.example.shared")
        }
        let withoutUUID = try plist(["MCMMetadataIdentifier": "group.com.example.shared"])
        XCTAssertEqual(try AppGroupPaths.identifier(from: withoutUUID, container: path), "group.com.example.shared")
    }

    func testMalformedMismatchedOversizedAndUnsafeMetadataAreRejected() throws {
        let path = AppGroupPaths.root + "/" + UUID().uuidString
        for object: [String: Any] in [
            [:], ["MCMMetadataIdentifier": 1],
            ["MCMMetadataIdentifier": "group.com.example.shared", "MCMMetadataUUID": UUID().uuidString],
            ["MCMMetadataIdentifier": "group.com.example.shared", "MCMMetadataUUID": Data([1])],
            ["MCMMetadataIdentifier": "group.bad\ninjected"], ["MCMMetadataIdentifier": "../outside"],
            ["MCMMetadataIdentifier": "group.bad\n"],
            ["MCMMetadataIdentifier": String(repeating: "a", count: 513)]
        ] { XCTAssertThrowsError(try AppGroupPaths.identifier(from: plist(object), container: path)) }
        XCTAssertThrowsError(try AppGroupPaths.identifier(from: Data(repeating: 0, count: 1_048_577), container: path))
        XCTAssertThrowsError(try AppGroupPaths.identifier(from: Data("not a plist".utf8), container: path))
    }

    func testScannerMergesRootAndDBDeduplicatesAliasesAndNeverInspectsOtherPaths() async throws {
        let a = UUID().uuidString, b = UUID().uuidString
        let pa = AppGroupPaths.root + "/" + a, pb = AppGroupPaths.root + "/" + b
        let access = GroupTestAccess(names: [a, "not-a-uuid", "../" + b], results: [
            pa: .group(group(pa, id: "group.com.example.a")), pb: .group(group(pb, id: "group.com.example.b"))
        ])
        let result = try await AppGroupScanner(files: access).scan(knownPaths: [
            pa, "/private" + pa, pb, "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        ])
        XCTAssertEqual(result.candidateCount, 2)
        XCTAssertEqual(result.scannedCount, 2)
        XCTAssertEqual(Set(result.containers.map(\.path)), [pa, pb])
        let visited = await access.visited
        XCTAssertEqual(Set(visited), [pa, pb])
        XCTAssertEqual(visited.count, 2)
        XCTAssertNil(result.rootIssue)
    }

    func testDeniedRootUsesDBCandidatesInsteadOfReturningAnUnexplainedEmptyList() async throws {
        let path = AppGroupPaths.root + "/" + UUID().uuidString
        let access = GroupTestAccess(names: [], denyRoot: true, results: [path: .group(group(path))])
        let result = try await AppGroupScanner(files: access).scan(knownPaths: [path])
        XCTAssertEqual(result.containers.count, 1)
        XCTAssertNotNil(result.rootIssue)
        XCTAssertNil(result.containers[0].groupID)
        XCTAssertTrue(result.containers[0].canOpen)
        let empty = try await AppGroupScanner(files: GroupTestAccess(names: [], denyRoot: true)).scan(knownPaths: [])
        XCTAssertTrue(empty.containers.isEmpty)
        XCTAssertNotNil(empty.rootIssue)
    }

    func testMissingLinksAndDeniedCandidatesAreDistinguished() async throws {
        let paths = (0..<3).map { _ in AppGroupPaths.root + "/" + UUID().uuidString }
        let access = GroupTestAccess(names: [], results: [paths[0]: .missing, paths[1]: .rejected, paths[2]: .denied])
        let result = try await AppGroupScanner(files: access).scan(knownPaths: paths)
        XCTAssertEqual(result.missingCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.containers.count, 1)
        XCTAssertEqual(result.containers[0].path, paths[2])
        XCTAssertFalse(result.containers[0].canOpen)
        XCTAssertFalse(result.containers[0].issues.isEmpty)
    }

    func testScannerLimitsCandidateCountBeforeInspectingAnything() async throws {
        let access = GroupTestAccess(names: (0...AppGroupScanner.maximumContainers).map { _ in UUID().uuidString })
        do { _ = try await AppGroupScanner(files: access).scan(knownPaths: []); XCTFail("Limit ignored") } catch {}
        let visited = await access.visited
        XCTAssertTrue(visited.isEmpty)
    }

    @MainActor
    func testScanYieldsForUIAndCancellationStopsBeforeNextContainer() async throws {
        let a = AppGroupPaths.root + "/" + UUID().uuidString, b = AppGroupPaths.root + "/" + UUID().uuidString
        let access = GroupTestAccess(names: [], results: [a: .group(group(a)), b: .group(group(b))])
        let gate = GroupTestGate()
        let started = expectation(description: "First group published")
        let task = Task {
            try await AppGroupScanner(files: access).scan(knownPaths: [a, b]) { partial in
                if partial.scannedCount == 1 { started.fulfill(); await gate.wait() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        var uiRan = false
        await Task { @MainActor in uiRan = true }.value
        XCTAssertTrue(uiRan)
        let before = await access.visited.count
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled scan completed") } catch is CancellationError {}
        let after = await access.visited.count
        XCTAssertEqual(before, 1)
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testCancelledModelRejectsLatePartialAndCompletion() async {
        let model = AppGroupScanModel(), gate = GroupTestGate()
        let partial = AppGroupScanSnapshot(containers: [], scannedCount: 1, candidateCount: 2, missingCount: 0, skippedCount: 0, rootIssue: nil, catalogIssue: nil)
        let late = AppGroupScanSnapshot(containers: [], scannedCount: 2, candidateCount: 2, missingCount: 0, skippedCount: 0, rootIssue: nil, catalogIssue: nil)
        let started = expectation(description: "Partial scan received")
        let task = Task {
            await model.load { publish in
                await publish(partial)
                started.fulfill()
                await gate.wait()
                await publish(late)
                return late
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancel()
        await gate.open()
        await task.value
        XCTAssertEqual(model.snapshot?.scannedCount, 1)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.complete)
        XCTAssertTrue(model.interrupted)
    }

    @MainActor
    func testModelReusesCompletedSnapshotAndOnlyReloadsOnExplicitRefresh() async {
        let model = AppGroupScanModel()
        let result = AppGroupScanSnapshot(containers: [], scannedCount: 0, candidateCount: 0, missingCount: 0, skippedCount: 0, rootIssue: nil, catalogIssue: nil)
        var calls = 0
        await model.load { _ in calls += 1; return result }
        await model.load { _ in calls += 1; return result }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.complete)
        await model.load(forceRefresh: true) { _ in calls += 1; return result }
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testModelKeepsErrorsSeparateFromAnEmptyConfirmedScan() async {
        let model = AppGroupScanModel()
        await model.load { _ in throw RunnerError("scan failed") }
        XCTAssertEqual(model.error, "scan failed")
        XCTAssertFalse(model.complete)
        let result = AppGroupScanSnapshot(containers: [], scannedCount: 0, candidateCount: 0, missingCount: 0, skippedCount: 0, rootIssue: nil, catalogIssue: nil)
        await model.load { _ in result }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.complete)
    }

    func testGroupSearchUsesOnlyGroupIdentifierAndPath() {
        let path = AppGroupPaths.root + "/" + UUID().uuidString
        let record = group(path, id: "group.com.example.shared")
        XCTAssertTrue(record.matches("EXAMPLE"))
        XCTAssertTrue(record.matches(URL(fileURLWithPath: path).lastPathComponent))
        XCTAssertFalse(record.matches("unverified app name"))
        XCTAssertTrue(record.matches(""))
    }

    func testGroupSearchMatchesIdentifierAndUUID() {
        let path = AppGroupPaths.root + "/ABCDEFAB-1234-4234-8234-ABCDEFABCDEF"
        let record = AppGroupContainer(path: path, groupID: "group.example.documents", canOpen: true, issues: [])
        for query in ["GROUP.EXAMPLE", "abcdefab-1234"] {
            XCTAssertTrue(record.matches(query), query)
        }
        XCTAssertFalse(record.matches("unrelated"))
    }

    func testGroupSearchTrimsWhitespaceAndClearRestoresAllRecords() {
        let record = group(AppGroupPaths.root + "/" + UUID().uuidString, id: "group.example.shared")
        XCTAssertTrue(record.matches(" \n EXAMPLE \t"))
        XCTAssertTrue(record.matches(" \n\t "))
        XCTAssertTrue(record.matches(""))
        XCTAssertFalse(record.matches(" \n missing \t"))
    }

    func testUnknownGroupCanBeFoundByUUID() {
        let record = group(AppGroupPaths.root + "/ABCDEFAB-1234-4234-8234-ABCDEFABCDEF")
        XCTAssertTrue(record.matches("abcdefab"))
        XCTAssertFalse(record.matches("com.example.app"))
        XCTAssertNil(record.groupID)
    }

    func testDBFallbackIdentifiesGroupFromLaunchServices() async throws {
        let path = AppGroupPaths.root + "/" + UUID().uuidString
        let catalog = ParsedApplicationCatalog(layout: "fixture", applications: [], sharedGroupPaths: [],
            ambiguousContainerCount: 0, sharedGroupIdentifiers: [path: ["group.other.exact"]])
        let access = GroupTestAccess(names: [], denyRoot: true, results: [path: .group(group(path))])
        let result = try await AppGroupScanner(files: access).scan(knownPaths: [], catalog: catalog)
        let container = try XCTUnwrap(result.containers.first)
        XCTAssertEqual(container.groupID, "group.other.exact")
        XCTAssertEqual(container.identificationSource, "LaunchServices DB")
        XCTAssertTrue(container.matches("group.other"))
        XCTAssertTrue(container.matches("GROUP.OTHER"))
    }

    func testMetadataWinsAndDBConflictsAreReported() async throws {
        let a = AppGroupPaths.root + "/" + UUID().uuidString
        let b = AppGroupPaths.root + "/" + UUID().uuidString
        let c = AppGroupPaths.root + "/" + UUID().uuidString
        let input = ParsedApplicationCatalog(layout: "fixture", applications: [], sharedGroupPaths: [],
            ambiguousContainerCount: 0, sharedGroupIdentifiers: [
                a: ["group.db.wrong"], b: ["group.first", "group.second"], c: ["group.com.example.app"]
            ])
        let access = GroupTestAccess(names: [], results: [a: .group(group(a, id: "group.metadata")), b: .group(group(b)), c: .denied])
        let result = try await AppGroupScanner(files: access).scan(knownPaths: [], catalog: input)
        let first = try XCTUnwrap(result.containers.first { $0.path == a })
        XCTAssertEqual(first.groupID, "group.metadata")
        XCTAssertEqual(first.identificationSource, "コンテナ管理情報")
        XCTAssertFalse(first.issues.isEmpty)
        XCTAssertNil(result.containers.first { $0.path == b }?.groupID)
        let denied = try XCTUnwrap(result.containers.first { $0.path == c })
        XCTAssertEqual(denied.groupID, "group.com.example.app")
        XCTAssertFalse(denied.canOpen)
    }

    func testManagerRejectsOutOfScopeInspectionWithoutAccessOrWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppGroupTests-\(UUID())")
        let manager = FileAccessManager(backupRoot: root)
        for path in ["/etc", AppGroupPaths.root, "/var/mobile/Containers/Data/Application/" + UUID().uuidString,
                     AppGroupPaths.root + "/" + UUID().uuidString + "/Library"] {
            do { _ = try await manager.inspectAppGroup(path: path); XCTFail("Out-of-scope read accepted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("AppGroup/UUID")) }
        }
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func group(_ path: String, id: String? = nil) -> AppGroupContainer {
        AppGroupContainer(path: path, groupID: id, canOpen: true, issues: [])
    }
    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}

private actor GroupTestAccess: AppGroupAccess {
    enum Result: Sendable { case group(AppGroupContainer), missing, rejected, denied }
    let names: [String]
    let denyRoot: Bool
    let results: [String: Result]
    private(set) var visited: [String] = []
    init(names: [String], denyRoot: Bool = false, results: [String: Result] = [:]) {
        self.names = names; self.denyRoot = denyRoot; self.results = results
    }
    func appGroupCandidateNames() throws -> [String] {
        if denyRoot { throw POSIXError(.EACCES) }
        return names
    }
    func inspectAppGroup(path: String) throws -> AppGroupContainer? {
        visited.append(path)
        switch results[path] ?? .missing {
        case .group(let group): return group
        case .missing: throw POSIXError(.ENOENT)
        case .rejected: return nil
        case .denied: throw POSIXError(.EACCES)
        }
    }
}

private actor GroupTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
