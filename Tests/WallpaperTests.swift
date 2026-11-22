import XCTest
@testable import RunnerCore

final class WallpaperTests: XCTestCase {
    private let provider = "com.apple.WallpaperKit.CollectionsPoster"

    func testStoredAndDeflatedPackagesPreserveHiddenAssetsAndRemapNumericIDs() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for compressed in [false, true] {
            let zip = try makeZIP(root, entries: fixture(prefix: "ordered-descriptors/example/"), compressed: compressed)
            let archive = try WallpaperImporter.inspect(zip)
            let descriptor = try XCTUnwrap(archive.descriptors.first)
            XCTAssertEqual(descriptor.provider, provider)
            XCTAssertEqual(archive.descriptors.count, 1)
            let before = try Data(contentsOf: zip)
            let staged = try WallpaperImporter.stage(descriptor, from: archive, in: root)
            XCTAssertNotNil(UUID(uuidString: staged.lastPathComponent))
            let identifier = try String(contentsOf: staged.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"), encoding: .utf8)
            XCTAssertNotEqual(identifier, "7420")
            XCTAssertNotNil(Int(identifier))
            let userInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: staged.appendingPathComponent("versions/1/contents/com.apple.posterkit.provider.contents.userInfo")), format: nil) as! [String: Any]
            XCTAssertEqual((userInfo["nested"] as? [String: Int])?["wallpaperRepresentingIdentifier"], Int(identifier))
            XCTAssertEqual(userInfo["untouched"] as? String, "keep")
            XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("versions/1/contents/.hidden")), Data("hidden".utf8))
            XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("versions/1/contents/empty")), Data())
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("versions/1/scratch").path))
            XCTAssertEqual(try Data(contentsOf: zip), before)
        }
    }

    func testOnlyTendieLayoutIsAcceptedRegardlessOfZipExtension() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "Data/" + WallpaperPaths.store + "/Extensions/"
        var entries = try fixture(prefix: base + provider + "/descriptors/A/")
        entries += try fixture(prefix: base + "com.apple.MercuryPoster/descriptors/B/", identifier: "celosia.color")
        entries += try fixture(prefix: base + provider + "/configurations/C/")
        entries += [("Data/" + WallpaperPaths.store + "/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3", Data("DB".utf8)),
                    ("Data/Library/Preferences/com.apple.PosterBoard.plist", Data("settings".utf8))]
        XCTAssertThrowsError(try WallpaperImporter.inspect(makeZIP(root, entries: entries)))
        let dataExport = try makeZIP(root, entries: entries)
        let renamedExport = dataExport.deletingPathExtension().appendingPathExtension("zip")
        try FileManager.default.moveItem(at: dataExport, to: renamedExport)
        XCTAssertThrowsError(try WallpaperImporter.inspect(renamedExport))
        let tendie = try makeZIP(root, entries: fixture(prefix: "descriptor/A/") + fixture(prefix: "mercury-descriptor/B/", identifier: "celosia.color"))
        let renamed = tendie.deletingPathExtension().appendingPathExtension("zip")
        try FileManager.default.moveItem(at: tendie, to: renamed)
        let archive = try WallpaperImporter.inspect(renamed)
        XCTAssertEqual(archive.descriptors.count, 2)
        let mercury = try XCTUnwrap(archive.descriptors.first { $0.provider == "com.apple.MercuryPoster" })
        let staged = try WallpaperImporter.stage(mercury, from: archive, in: root)
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"), encoding: .utf8), "celosia.color")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Library").path))
        let photos = try WallpaperImporter.inspect(makeZIP(root, entries: fixture(prefix: "video-descriptor/A/", identifier: "photo")))
        XCTAssertEqual(photos.descriptors.first?.provider, "com.apple.PhotosUIPrivate.PhotosPosterProvider")
        let plural = try makeZIP(root, entries: fixture(prefix: "descriptor/A/"))
        let tendies = plural.deletingPathExtension().appendingPathExtension("tendies")
        try FileManager.default.moveItem(at: plural, to: tendies)
        XCTAssertEqual(try WallpaperImporter.inspect(tendies).descriptors.count, 1)
        let resource = try makeZIP(root, entries: fixture(prefix: "descriptor/A/") + [
            ("descriptor/A/versions/1/contents/Data/asset.bin", Data([1, 2, 3]))
        ])
        let package = try WallpaperImporter.inspect(resource)
        let output = try WallpaperImporter.stage(package.descriptors[0], from: package, in: root)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("versions/1/contents/Data/asset.bin")), Data([1, 2, 3]))
    }

    func testDangerousPathsDuplicatesLinksAndUnsupportedFormatsAreRejected() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["../escape", "/absolute", "a/../../escape", "a\\escape", "a//escape", "a/./escape", "a/\0escape", "a:escape"] {
            let url = try makeZIP(root, entries: [(name, Data("bad".utf8))])
            XCTAssertThrowsError(try WallpaperImporter.inspect(url), name)
        }
        for names in [["a", "A"], ["a", "a/file"], ["é", "e\u{301}"]] {
            XCTAssertThrowsError(try WallpaperImporter.inspect(makeZIP(root, entries: names.map { ($0, Data()) })))
        }
        let link = try makeZIP(root, entries: [("link", Data("../outside".utf8))], symlink: true)
        XCTAssertThrowsError(try WallpaperImporter.inspect(link))
        for method in [12, 14] {
            XCTAssertThrowsError(try WallpaperImporter.inspect(makeZIP(root, entries: [("x", Data("x".utf8))], method: method)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }

    func testPayloadCRCFailureAndChangedArchivesCleanUpStaging() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try makeZIP(root, entries: fixture(prefix: "descriptor/A/"))
        var data = try Data(contentsOf: zip)
        let marker = try XCTUnwrap(data.range(of: Data("hidden".utf8)))
        data[marker.lowerBound] ^= 0xff
        try data.write(to: zip)
        let archive = try WallpaperImporter.inspect(zip) // Identifier is good, asset is corrupt.
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertThrowsError(try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        data.append(0)
        try data.write(to: zip)
        XCTAssertThrowsError(try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testLocalHeaderMismatchAndTruncatedDirectoryAreRejected() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try makeZIP(root, entries: fixture(prefix: "descriptor/A/"))
        var data = try Data(contentsOf: zip)
        data[30] ^= 1 // Mismatch the first local filename against its central entry.
        try data.write(to: zip)
        XCTAssertThrowsError(try WallpaperImporter.inspect(zip))
        try data.dropLast(10).write(to: zip)
        XCTAssertThrowsError(try WallpaperImporter.inspect(zip))
    }

    func testDeclaredBoundsEncryptionAndCancellationFailBeforeExtraction() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try makeZIP(root, entries: fixture(prefix: "descriptor/A/"), compressed: true)
        let original = try Data(contentsOf: zip)
        let central = try XCTUnwrap(original.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        var oversized = original
        let count = UInt32(WallpaperZIP.maximumFileBytes + 1)
        for byte in 0..<4 { oversized[central + 24 + byte] = UInt8(truncatingIfNeeded: count >> (byte * 8)) }
        try oversized.write(to: zip)
        XCTAssertThrowsError(try WallpaperImporter.inspect(zip))
        var encrypted = original
        encrypted[central + 8] |= 1
        try encrypted.write(to: zip)
        XCTAssertThrowsError(try WallpaperImporter.inspect(zip))
        try original.write(to: zip)
        let archive = try WallpaperImporter.inspect(zip)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root)
        }
        do { _ = try await task.value; XCTFail("Cancelled extraction succeeded") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [zip.lastPathComponent])
    }

    func testRefreshPreservesFormatAndAllOtherSettingsAndUsesConfirmedBackedUpSave() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        for format: PropertyListSerialization.PropertyListFormat in [.binary, .xml] {
            let original = try PropertyListSerialization.data(fromPropertyList: [
                "PBF_RESET_FILE_PROTECTIONS": false,
                "PBF_LOCALE_DID_CHANGE": true,
                "PersistedPosterContainerBundleIdentifiers": ["preserve"],
                "other": Data([0, 1, 2])
            ], format: format, options: 0)
            let updated = try WallpaperImporter.refreshSettings(original)
            var actualFormat = PropertyListSerialization.PropertyListFormat.binary
            let value = try PropertyListSerialization.propertyList(from: updated, format: &actualFormat) as! [String: Any]
            XCTAssertEqual(actualFormat, format)
            XCTAssertEqual(value["PBF_RESET_FILE_PROTECTIONS"] as? Bool, true)
            XCTAssertEqual(value["PBF_LOCALE_DID_CHANGE"] as? Bool, false)
            XCTAssertEqual(value["PersistedPosterContainerBundleIdentifiers"] as? [String], ["preserve"])
            XCTAssertEqual(value["other"] as? Data, Data([0, 1, 2]))
            let path = root.appendingPathComponent("settings.plist")
            try original.write(to: path)
            let operation = FileWriteOperation.savePropertyList(path: path.path, data: updated, original: original)
            let denied = try await manager.prepareWrite(operation)
            do { _ = try await manager.commitWrite(denied, userConsented: false); XCTFail("Unconfirmed refresh accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: path), original)
            let request = try await manager.prepareWrite(operation)
            let receipt = try await manager.commitWrite(request, userConsented: true)
            XCTAssertEqual(try Data(contentsOf: path), updated)
            XCTAssertEqual(try Data(contentsOf: receipt.backupDirectory.appendingPathComponent("original")), original)
        }
    }

    func testDestinationValidationAndWallpaperUndoRequireVerifiedCreation() throws {
        let root = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let valid = try WallpaperPaths.descriptors(container: root, provider: provider)
        XCTAssertNoThrow(try WallpaperPaths.validateDestination(valid))
        for path in ["/tmp/Data", root + "/Library", valid + "/..", valid.replacingOccurrences(of: "/61/", with: "/59/"),
                     valid.replacingOccurrences(of: "descriptors", with: "configurations")] {
            XCTAssertThrowsError(try WallpaperPaths.validateDestination(path))
        }
        let source = URL(fileURLWithPath: "/tmp/" + UUID().uuidString)
        XCTAssertEqual(try FileWriteOperation.addWallpaper(source: source, directory: valid).paths().destination?.lastPathComponent, source.lastPathComponent)
        let manifest = FileBackupManifest(version: 2, created: Date(), operation: "壁紙を追加", kind: "addWallpaper", sourcePath: source.path,
                                          destinationPath: valid + "/" + source.lastPathComponent, destinationWasAbsent: true, parent: nil, entries: [:], hashes: [:])
        let incomplete = FileBackupRecord(id: UUID().uuidString, directory: source, manifest: manifest, outcome: nil)
        XCTAssertThrowsError(try incomplete.restoration())
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let record = FileBackupRecord(id: incomplete.id, directory: source, manifest: manifest,
                                     outcome: FileBackupOutcome(succeeded: true, changedPath: manifest.destinationPath, snapshot: [".": try FileBackupStore.Snapshot(path: workspace.path)]))
        guard case .removeCreated(let path) = try record.restoration() else { return XCTFail("Wrong undo plan") }
        XCTAssertEqual(path, manifest.destinationPath)
    }

    func testOptionalReferenceTendieReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["TENDIE_REFERENCE_FILE"] else {
            throw XCTSkip("Set TENDIE_REFERENCE_FILE to locally validate a private tendie; it is never bundled.")
        }
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try WallpaperImporter.inspect(URL(fileURLWithPath: path))
        XCTAssertFalse(archive.descriptors.isEmpty)
        for descriptor in archive.descriptors where descriptor.provider == provider {
            let result = try WallpaperImporter.stage(descriptor, from: archive, in: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("versions").path))
        }
        XCTAssertEqual(try FileBackupStore.Snapshot(path: path), archive.snapshot)
        print("Reference tendie: \(archive.descriptors.count) supported wallpapers; Collections staging verified.")
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(prefix: String, identifier: String = "7420") throws -> [(String, Data)] {
        let userInfo = try PropertyListSerialization.data(fromPropertyList: [
            "nested": ["wallpaperRepresentingIdentifier": 7420], "untouched": "keep"
        ], format: .binary, options: 0)
        return [
            (prefix + "com.apple.posterkit.provider.descriptor.identifier", Data(identifier.utf8)),
            (prefix + "providerInfo.plist", try PropertyListSerialization.data(fromPropertyList: ["test": true], format: .binary, options: 0)),
            (prefix + "versions/1/contents/com.apple.posterkit.provider.contents.userInfo", userInfo),
            (prefix + "versions/1/contents/.hidden", Data("hidden".utf8)),
            (prefix + "versions/1/contents/empty", Data()),
            (prefix + "versions/1/scratch/cache.db", Data("do not copy".utf8))
        ]
    }

    // An independent standard-library writer supplies stored/deflated/corrupt fixtures.
    private func makeZIP(_ root: URL, entries: [(String, Data)], compressed: Bool = false, symlink: Bool = false, method: Int? = nil) throws -> URL {
        let specification = root.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: entries.map { ["name": $0.0, "data": $0.1.base64EncodedString()] }).write(to: specification)
        defer { try? FileManager.default.removeItem(at: specification) }
        let zip = root.appendingPathComponent(UUID().uuidString + ".tendie")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
        import sys,json,zipfile,base64
        entries=json.load(open(sys.argv[1]))
        with zipfile.ZipFile(sys.argv[2],'w',compression=int(sys.argv[3])) as z:
            for item in entries:
                info=zipfile.ZipInfo(item['name'])
                info.compress_type=int(sys.argv[3])
                info.create_system=3
                info.external_attr=(0o120777 if sys.argv[4]=='true' else 0o100644)<<16
                z.writestr(info,base64.b64decode(item['data']))
        """, specification.path, zip.path, String(method ?? (compressed ? 8 : 0)), String(symlink)]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RunnerError("Test ZIP creation failed.") }
        return zip
    }
}
