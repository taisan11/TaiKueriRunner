import XCTest
@testable import RunnerCore

final class WallpaperPathTests: XCTestCase {
    private let provider = "com.apple.WallpaperKit.CollectionsPoster"

    func testAncestorWalkNormalizesVarAliasBeforeComputingRelativeComponents() throws {
        let root = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let path = root + "/" + WallpaperPaths.store + "/Extensions/" + provider
        let canonical = try WallpaperPaths.directoryAncestors(path, container: root)
        for container in [root, "/private" + root] {
            for target in [path, "/private" + path] {
                XCTAssertEqual(try WallpaperPaths.directoryAncestors(target, container: container), canonical)
            }
        }
        XCTAssertEqual(canonical.first, root)
        XCTAssertEqual(canonical.last, path)
        XCTAssertEqual(try WallpaperPaths.directoryAncestors("/private" + root, container: root), [root])
        XCTAssertTrue(canonical.dropFirst().allSatisfy { $0.hasPrefix(root + "/") })
        XCTAssertFalse(canonical.contains { $0.hasPrefix("/private/") })
    }

    func testAliasNormalizationDoesNotAllowOtherContainersOrPrefixLookalikes() throws {
        let root = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        for target in [
            root + "-other/Library",
            "/var/mobile/Containers/Data/Application/" + UUID().uuidString + "/Library",
            "/private/var/mobile/Containers/Data/Application/" + UUID().uuidString + "/Library",
            "/private/var2/mobile/Containers/Data/Application/anything",
            root + "/../../outside",
            "/var",
            "relative/Library",
            root + "/\0"
        ] {
            XCTAssertThrowsError(try WallpaperPaths.directoryAncestors(target, container: root), target)
        }
        XCTAssertThrowsError(try WallpaperPaths.directoryAncestors("/var/mobile", container: "/"))
        XCTAssertEqual(try WallpaperPaths.normalized("/private/var2/data"), "/private/var2/data")
        XCTAssertEqual(try WallpaperPaths.normalized(root + "/link/file"), root + "/link/file")
    }

    func testListedChildUsesItsValidatedNameAndCanonicalParent() throws {
        let parent = "/var/mobile/Containers/Data/Application/" + UUID().uuidString + "/" + WallpaperPaths.store + "/Extensions"
        let entry = FileEntry(path: "/private" + parent + "/" + provider, name: provider, isDirectory: true,
                              isSymbolicLink: false, size: 1, modified: nil)
        XCTAssertEqual(try WallpaperPaths.listedEntry(entry, in: parent).path, parent + "/" + provider)
        XCTAssertEqual(try WallpaperPaths.listedEntry(entry, in: "/private" + parent).path, parent + "/" + provider)
        let wrongURL = FileEntry(path: "/some/other/location", name: provider, isDirectory: false, isSymbolicLink: false, size: 0, modified: nil)
        XCTAssertEqual(try WallpaperPaths.listedEntry(wrongURL, in: parent).path, parent + "/" + provider)
        for name in ["../outside", "..", ".", "", "a/b"] {
            let unsafe = FileEntry(path: "/unused", name: name, isDirectory: true, isSymbolicLink: false, size: 0, modified: nil)
            XCTAssertThrowsError(try WallpaperPaths.listedEntry(unsafe, in: parent))
        }
    }

    func testWallpaperValidationAcceptsBothSpellingsWithoutExpandingWritableLocations() throws {
        let root = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let directory = try WallpaperPaths.descriptors(container: root, provider: provider)
        XCTAssertNoThrow(try WallpaperPaths.validateDestination("/private" + directory))
        XCTAssertEqual(try WallpaperPaths.container("/private" + root), root)
        for location in InstalledWallpaper.Location.allCases {
            let path = root + "/" + WallpaperPaths.store + "/Extensions/" + provider + "/" + location.rawValue + "/" + UUID().uuidString
            XCTAssertEqual(try WallpaperPaths.installed("/private" + path).container, root)
            XCTAssertEqual(try WallpaperPaths.installed("/private" + path).location, location)
            if location != .descriptors {
                XCTAssertThrowsError(try WallpaperPaths.validateDestination("/private" + URL(fileURLWithPath: path).deletingLastPathComponent().path))
            }
        }
    }

    func testReportedVarPrivateVarMixReproducesOldZeroAndLoadsWithFixedAdapter() async throws {
        let backingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperPathTests-\(UUID())")
        try FileManager.default.createDirectory(at: backingRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: backingRoot) }
        let virtualRoot = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let store = "/" + WallpaperPaths.store + "/Extensions/" + provider
        let descriptorSuffix = store + "/descriptors/" + UUID().uuidString
        let configurationSuffix = store + "/configurations/" + UUID().uuidString
        for suffix in [descriptorSuffix, configurationSuffix] {
            let directory = backingRoot.path + suffix
            try FileManager.default.createDirectory(atPath: directory + "/versions/1/contents/Test.wallpaper", withIntermediateDirectories: true)
            try Data("7420".utf8).write(to: URL(fileURLWithPath: directory + "/com.apple.posterkit.provider.descriptor.identifier"))
            try Data([1]).write(to: URL(fileURLWithPath: directory + "/versions/1/contents/Test.wallpaper/Background.HEIC"))
        }

        func backing(_ path: String) throws -> String {
            let normalized = try WallpaperPaths.normalized(path)
            guard normalized == virtualRoot || normalized.hasPrefix(virtualRoot + "/") else { throw RunnerError("Outside fixture") }
            return backingRoot.path + normalized.dropFirst(virtualRoot.count)
        }
        func inspect(_ path: String) throws -> FileBackupStore.Snapshot {
            try FileBackupStore.Snapshot(path: backing(path))
        }
        func enumerateLikeFoundation(_ path: String) throws -> [FileEntry] {
            let normalized = try WallpaperPaths.normalized(path)
            return try FileManager.default.contentsOfDirectory(atPath: backing(path)).map { name in
                let info = try inspect(normalized + "/" + name)
                return FileEntry(path: "/private" + normalized + "/" + name, name: name,
                                 isDirectory: info.isDirectory, isSymbolicLink: !info.isDirectory && !info.isRegular,
                                 size: info.size, modified: nil)
            }
        }
        let read: (String, Int) throws -> Data = { path, maximum in
            try StableFileReader.read(path: backing(path), maximumBytes: maximum) { $0 }
        }

        // Exact r2 failure: top-level names are readable, but subsequent URL
        // paths have /private/var and get sliced using the shorter /var root.
        let old = WallpaperLibraryReader(list: { path in
            var current = virtualRoot
            for component in [""] + path.dropFirst(virtualRoot.count).split(separator: "/").map(String.init) {
                if !component.isEmpty { current += "/" + component }
                guard try inspect(current).isDirectory else { throw POSIXError(.ENOTDIR) }
            }
            return try enumerateLikeFoundation(path)
        }, read: read, inspect: inspect)
        let broken = try await old.load(container: virtualRoot, backups: [])
        XCTAssertTrue(broken.items.isEmpty)
        XCTAssertEqual(broken.diagnostics?.counters["provider.directories"], 1)
        XCTAssertEqual(broken.diagnostics?.counters["enumerated.entries"], 2)
        XCTAssertEqual(broken.diagnostics?.counters["optionalDirectory.missing"], 5)

        // Use the same path builder and child adapter as FileAccessManager.
        let fixed = WallpaperLibraryReader(list: { path in
            for ancestor in try WallpaperPaths.directoryAncestors(path, container: virtualRoot) {
                guard try inspect(ancestor).isDirectory else { throw POSIXError(.ENOTDIR) }
            }
            return try enumerateLikeFoundation(path).map { try WallpaperPaths.listedEntry($0, in: path) }
        }, read: read, inspect: inspect)
        let installedPath = virtualRoot + descriptorSuffix
        let state = try inspect(installedPath)
        let change = UUID()
        let imported = makeRecord(path: "/private" + installedPath, changedPath: installedPath,
                                  state: state, date: 100, change: change, isRefresh: false)
        let refreshPath = "/private" + virtualRoot + "/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"
        let refreshed = makeRecord(path: refreshPath, changedPath: refreshPath, state: state, date: 101, change: change, isRefresh: true)
        let loaded = try await fixed.load(container: virtualRoot, backups: [imported, refreshed])
        XCTAssertEqual(loaded.items.count, 2)
        XCTAssertEqual(loaded.unreadableCount, 0)
        let managed = try XCTUnwrap(loaded.items.first { $0.path == installedPath })
        XCTAssertTrue(managed.isManaged)
        XCTAssertTrue(managed.previewPath?.hasPrefix(installedPath + "/versions/") == true)
        XCTAssertEqual(try WallpaperPaths.installed(managed.path).container, virtualRoot)
        XCTAssertTrue(loaded.items.allSatisfy { !$0.path.hasPrefix("/private/") })
        XCTAssertFalse(loaded.refreshRequired)
        XCTAssertEqual(loaded.latestChange, Date(timeIntervalSince1970: 101))
    }

    private func makeRecord(path: String, changedPath: String, state: FileBackupStore.Snapshot, date: TimeInterval,
                            change: UUID, isRefresh: Bool) -> FileBackupRecord {
        let manifest = FileBackupManifest(version: 2, created: Date(timeIntervalSince1970: date), operation: "test",
            kind: isRefresh ? "savePropertyList" : "addWallpaper", sourcePath: isRefresh ? path : nil,
            destinationPath: isRefresh ? nil : path, destinationWasAbsent: !isRefresh,
            parent: nil, entries: [:], hashes: [:],
            wallpaper: WallpaperBackupMetadata(changeID: change, title: "Test", package: nil, isRefresh: isRefresh))
        return FileBackupRecord(id: UUID().uuidString, directory: URL(fileURLWithPath: "/unused"), manifest: manifest,
                               outcome: FileBackupOutcome(succeeded: true, changedPath: changedPath, snapshot: [".": state]))
    }
}
