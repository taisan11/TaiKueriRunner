import XCTest
import ImageIO
import CoreGraphics
@testable import RunnerCore

final class KeypadTests: XCTestCase {
    func testFilenameParsingSeparatesEveryKeyAndStyleWithoutSubstringGuessing() {
        for key in KeypadKey.allCases {
            for suffix in ["--white.png", "--white-bold.png", "--mask.png", "-hi-white.png", "-hi-mask.png", "--mask-bold.png"] {
                let parsed = KeypadAssetName("other-\(key.rawValue)-A B C\(suffix)")
                XCTAssertEqual(parsed?.key, key)
                XCTAssertEqual(parsed?.bold, suffix.contains("bold"))
                XCTAssertEqual(parsed?.highlighted, suffix.contains("hi-"))
            }
        }
        XCTAssertEqual(KeypadAssetName("ru-5-М Н О П--white-bold.png")?.locale, "ru")
        XCTAssertEqual(KeypadAssetName("other-0-+--mask.png")?.key, .zero)
        for invalid in ["icon1.png", "en-12---white.png", "en-A---white.png", "../en-1---white.png", "en-1---white.plist",
                        "en-1---white.png/file", "en-1---unknown.png", "en-1---white.png\0", "-1---white.png"] {
            XCTAssertNil(KeypadAssetName(invalid), invalid)
        }
    }

    func testDestinationAllowlistHandlesVarAliasAndRefusesUnrelatedCaches() throws {
        for version in 8...10 {
            let directory = "/var/mobile/Library/Caches/TelephonyUI-\(version)"
            XCTAssertThrowsError(try KeypadPaths.root(for: directory))
            XCTAssertThrowsError(try KeypadPaths.validateFile(directory + "/other-1---white.png"))
            XCTAssertThrowsError(try KeypadPaths.validateFile("/private" + directory + "/other-1---white.png"))
        }
        let container = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let directory = try KeypadPaths.phoneDirectory(container)
        XCTAssertEqual(try KeypadPaths.root(for: directory), container)
        XCTAssertNoThrow(try KeypadPaths.validateFile("/private" + directory + "/other-1---white.png"))
        for path in ["/var/mobile/Library/Caches/TelephonyUI-11", "/var/mobile/Library/Preferences",
                     container + "/Library/Caches/Other", "/etc/Library/Caches/TelephonyUI-10"] {
            XCTAssertThrowsError(try KeypadPaths.root(for: path))
        }
        XCTAssertThrowsError(try KeypadPaths.validateFile(directory + "/settings.plist"))
    }

    func testPassthmImportPreservesVariantsAndUsesHighestVersionDeterministically() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let red = try image(red: 1), blue = try image(red: 0)
        let url = try zip(root, entries: [
            ("Theme/TelephonyUI-8/en-1---white.png", red),
            ("Theme/TelephonyUI-10/en-1---white.png", blue),
            ("Theme/TelephonyUI-10/en-1---mask.png", red),
            ("Theme/TelephonyUI-10/ru-1---white-bold.png", red),
            ("Theme/TelephonyUI-9/2.jpg", blue),
            ("__MACOSX/._3.png", red), ("preview123.png", red), ("_big", Data())
        ])
        let original = try Data(contentsOf: url)
        let theme = try KeypadTheme.inspect(url)
        XCTAssertEqual(theme.keys, [.one, .two])
        XCTAssertEqual(theme.assets.count, 5)
        XCTAssertEqual(theme.image(for: .one, matching: KeypadAssetName("en-1---white.png")), blue)
        XCTAssertEqual(theme.image(for: .one, matching: KeypadAssetName("en-1---mask.png")), red)
        XCTAssertEqual(theme.image(for: .one, matching: KeypadAssetName("ru-1---white-bold.png")), red)
        XCTAssertEqual(theme.image(for: .one, matching: KeypadAssetName("ja-1---white.png")), blue)
        XCTAssertNil(theme.image(for: .nine))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testUnsafeArchivesDuplicateCandidatesInvalidImagesAndCRCFailWithoutExtraction() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try image(red: 1)
        for entries in [
            [("../1.png", png)], [("/1.png", png)], [("a\\1.png", png)],
            [("a/1.png", png), ("b/1.png", png)], [("1.png", Data("not an image".utf8))],
            [("preview.png", png)], [("A/1.png", png), ("a/1.png", png)]
        ] { XCTAssertThrowsError(try KeypadTheme.inspect(zip(root, entries: entries))) }
        let bad = try zip(root, entries: [("1.png", png)], symlink: true)
        XCTAssertThrowsError(try KeypadTheme.inspect(bad))
        let crc = try zip(root, entries: [("1.png", png)])
        var bytes = try Data(contentsOf: crc)
        let range = try XCTUnwrap(bytes.range(of: png))
        bytes[range.lowerBound + 20] ^= 1
        try bytes.write(to: crc)
        XCTAssertThrowsError(try KeypadTheme.inspect(crc))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("1.png").path))
    }

    func testRendererProducesBoundedPNGAndTransparentCircularCorners() throws {
        let input = try image(red: 1)
        let output = try KeypadImage.render(input, width: 150, height: 205, circular: true)
        let dimensions = try KeypadImage.pngDimensions(output)
        XCTAssertEqual(dimensions.0, 150); XCTAssertEqual(dimensions.1, 205)
        try KeypadImage.validate(output)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 150, height: 205, bitsPerComponent: 8, bytesPerRow: 600,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 150, height: 205))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(pixels[3], 0)
        // A non-square canvas keeps its original bounds but contains a circle,
        // not an ellipse stretched to fill the whole height.
        XCTAssertEqual(pixels[(5 * 150 + 75) * 4 + 3], 0)
        XCTAssertGreaterThan(pixels[(100 * 150 + 75) * 4 + 3], 0)
        for invalid in [0, -1, 2501] { XCTAssertThrowsError(try KeypadImage.render(input, width: invalid, height: 100, circular: false)) }
        XCTAssertThrowsError(try KeypadImage.pngDimensions(Data("not a PNG".utf8)))
    }

    func testPlanChangesOnlyEditedKeysAcrossObservedLocalesBoldAndAppearances() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root, names: ["en-1---white.png", "ru-1---white-bold.png", "other-1---mask.png", "other-2-A B C--white.png"])
        let worker = KeypadLibraryWorker(files: FileAccessManager(backupRoot: root.appendingPathComponent("Backups")))
        let snapshot = KeypadLibrarySnapshot(files: entries.map(\.file), previews: [:], issues: [])
        let plan = try await worker.plan(snapshot: snapshot, theme: nil, overrides: [.one: image(red: 0)], options: KeypadRenderOptions())
        XCTAssertEqual(plan.entries.count, 3)
        XCTAssertTrue(plan.entries.allSatisfy { $0.file.name.key == .one })
        for entry in plan.entries {
            let dimensions = try KeypadImage.pngDimensions(entry.data)
            XCTAssertEqual(dimensions.0, entry.file.width)
            XCTAssertEqual(dimensions.1, entry.file.height)
        }
        do {
            _ = try await worker.plan(snapshot: snapshot, theme: nil, overrides: [:], options: KeypadRenderOptions())
            XCTFail("Empty plan accepted")
        } catch {}
    }

    func testAutomaticSizingPreservesEachDeviceVariantWithOrWithoutCircularCrop() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        var entries: [KeypadWriteEntry] = []
        let specifications = [("other-1---white.png", 90, 120), ("other-1---white-bold.png", 144, 144), ("other-1---mask.png", 128, 96)]
        for (index, specification) in specifications.enumerated() {
            let directory = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            entries += try fixtures(directory, names: [specification.0], width: specification.1, height: specification.2)
        }
        let worker = KeypadLibraryWorker(files: FileAccessManager(backupRoot: root.appendingPathComponent("Backups")))
        let snapshot = KeypadLibrarySnapshot(files: entries.map(\.file), previews: [:], issues: [])
        for circular in [false, true] {
            let plan = try await worker.plan(snapshot: snapshot, theme: nil, overrides: [.one: image(red: 0)],
                                             options: KeypadRenderOptions(circular: circular))
            XCTAssertEqual(plan.entries.count, entries.count)
            for entry in plan.entries {
                let dimensions = try KeypadImage.pngDimensions(entry.data)
                XCTAssertEqual(dimensions.0, entry.file.width)
                XCTAssertEqual(dimensions.1, entry.file.height)
                XCTAssertEqual(try FileBackupStore.Snapshot(path: entry.file.path), entry.file.snapshot)
            }
        }
    }

    func testConsentAndFailedSecondBackupLeaveAllOriginalsUntouched() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var count = 0
        XCTAssertThrowsError(try KeypadWriteTransaction.execute(entries, store: store, userConsented: false,
            validate: { _ in XCTFail("Consent was not checked first") },
            backup: { _ in XCTFail("Unconfirmed backup"); throw RunnerError("denied") },
            write: { _, _ in XCTFail("Unconfirmed write") }))
        XCTAssertThrowsError(try KeypadWriteTransaction.execute(entries, store: store, userConsented: true,
            validate: { _ in }, backup: { entry in
                count += 1
                if count == 2 { throw RunnerError("Simulated backup failure") }
                return try self.backup(entry, store: store)
            }, write: { _, _ in XCTFail("Mutation before all backups completed") }))
        for entry in entries { XCTAssertEqual(try FileBackupStore.Snapshot(path: entry.file.path), entry.file.snapshot) }
        XCTAssertEqual(try store.list().records.count, 1)
    }

    func testBatchBacksUpAllFilesBeforeWritingAndSupportsConfirmedRestoration() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let originals = try entries.map { try Data(contentsOf: URL(fileURLWithPath: $0.file.path)) }
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var backupsMade = 0
        _ = try KeypadWriteTransaction.execute(entries, store: store, userConsented: true, validate: { _ in },
            backup: { entry in backupsMade += 1; return try self.backup(entry, store: store) },
            write: { entry, backup in
                XCTAssertEqual(backupsMade, entries.count)
                XCTAssertEqual(try Data(contentsOf: backup.payload), originals[entries.firstIndex(where: { $0.file.path == entry.file.path })!])
                try self.write(entry)
            })
        let records = try store.list().records
        XCTAssertEqual(records.count, entries.count)
        XCTAssertTrue(records.allSatisfy { $0.outcome?.succeeded == true && $0.manifest.operationKind == "replaceKeypad" })
        let manager = FileAccessManager(backupRoot: store.root)
        for record in records {
            try store.verifyPayload(record)
            let request = try await manager.prepareWrite(.restoreBackup(id: record.id))
            _ = try await manager.commitWrite(request, userConsented: true)
        }
        for (entry, original) in Swift.zip(entries, originals) {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: entry.file.path)), original)
        }
    }

    func testPartialFailureIsReportedAndAllOriginalBackupsRemainRestorable() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var written = 0
        XCTAssertThrowsError(try KeypadWriteTransaction.execute(entries, store: store, userConsented: true, validate: { _ in },
            backup: { try self.backup($0, store: store) }, write: { entry, _ in
                if written == 1 { throw RunnerError("Simulated write denial") }
                try self.write(entry); written += 1
            })) { XCTAssertTrue($0.localizedDescription.contains("1/2")) }
        let records = try store.list().records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.outcome?.succeeded == true }.count, 1)
        for record in records { XCTAssertNoThrow(try record.restoration()); try store.verifyPayload(record) }
        XCTAssertEqual(try FileBackupStore.Snapshot(path: entries[1].file.path), entries[1].file.snapshot)
    }

    func testExternalChangesAndDuplicateTargetsAreRejectedBeforeMutation() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        try Data("external change".utf8).write(to: URL(fileURLWithPath: entries[0].file.path))
        for candidates in [entries, [entries[1], entries[1]]] {
            XCTAssertThrowsError(try KeypadWriteTransaction.execute(candidates, store: store, userConsented: true, validate: { _ in },
                backup: { try self.backup($0, store: store) }, write: { _, _ in XCTFail("Changed or duplicate file mutated") }))
        }
        XCTAssertEqual(try store.list().records.count, 0)
    }

    func testChangesDuringBackupAndParentReplacementAbortTheWholeBatch() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        var count = 0
        XCTAssertThrowsError(try KeypadWriteTransaction.execute(entries, store: store, userConsented: true, validate: { _ in },
            backup: { entry in
                let result = try self.backup(entry, store: store)
                count += 1
                if count == entries.count { try Data("changed after backup".utf8).write(to: URL(fileURLWithPath: entries[0].file.path)) }
                return result
            }, write: { _, _ in XCTFail("Post-backup change ignored") }))
        XCTAssertEqual(try store.list().records.count, 2)
        XCTAssertThrowsError(try KeypadWriteTransaction.execute([entries[1]], store: store, userConsented: true,
            validate: { _ in throw RunnerError("Parent directory replaced") },
            backup: { _ in XCTFail("Invalid parent backup"); throw RunnerError("invalid") },
            write: { _, _ in XCTFail("Invalid parent write") }))
    }

    func testCancelledBatchDoesNotWriteAndGenericKeypadRequestIsUnavailable() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try fixtures(root)
        let store = FileBackupStore(root: root.appendingPathComponent("Backups"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try KeypadWriteTransaction.execute(entries, store: store, userConsented: true,
                validate: { _ in throw RunnerError("Should be cancelled first") },
                backup: { _ in throw RunnerError("Should be cancelled first") },
                write: { _, _ in throw RunnerError("Should be cancelled first") })
        }
        do { _ = try await task.value; XCTFail("Cancelled batch succeeded") } catch {}
        XCTAssertEqual(try store.list().records.count, 0)
        let manager = FileAccessManager(backupRoot: store.root)
        do {
            _ = try await manager.prepareWrite(.replaceKeypad(path: "/var/mobile/Library/Caches/TelephonyUI-10/other-1---white.png"))
            XCTFail("Generic keypad operation accepted")
        } catch {}
    }

    func testPendingPlanRequiresConsentIsSingleUseAndCanBeCancelledOrRevoked() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try XCTUnwrap(fixtures(root).first)
        let container = "/var/mobile/Containers/Data/Application/" + UUID().uuidString
        let path = try KeypadPaths.phoneDirectory(container) + "/other-1---white.png"
        let file = KeypadCacheFile(path: path, name: local.file.name, snapshot: local.file.snapshot,
                                   directory: local.file.directory, width: local.file.width, height: local.file.height)
        let plan = KeypadWritePlan(entries: [KeypadWriteEntry(file: file, data: local.data)])
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let denied = try await manager.prepareKeypadChange(plan)
        do { _ = try await manager.commitWrite(denied, userConsented: false); XCTFail("Consent bypassed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ユーザー同意")) }
        do { _ = try await manager.commitWrite(denied, userConsented: true); XCTFail("Used request accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("無効")) }
        let cancelled = try await manager.prepareKeypadChange(plan)
        await manager.cancelWrite(cancelled)
        do { _ = try await manager.commitWrite(cancelled, userConsented: true); XCTFail("Cancelled request accepted") } catch {}
        let revoked = try await manager.prepareKeypadChange(plan)
        await manager.releaseAll()
        do { _ = try await manager.commitWrite(revoked, userConsented: true); XCTFail("Revoked request accepted") } catch {}
        XCTAssertEqual(try FileBackupStore(root: root.appendingPathComponent("Backups")).list().records.count, 0)
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    func testRemovedLockScreenPathsCannotBeReadExportedOrPreparedForWriting() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try XCTUnwrap(fixtures(root).first)
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        for version in 8...10 {
            for prefix in ["/var", "/private/var"] {
                let directory = prefix + "/mobile/Library/Caches/TelephonyUI-\(version)"
                let file = KeypadCacheFile(path: directory + "/other-1---white.png", name: local.file.name, snapshot: local.file.snapshot,
                    directory: local.file.directory, width: local.file.width, height: local.file.height)
                do { _ = try await manager.readKeypadDirectory(directory); XCTFail("Removed directory read") }
                catch { XCTAssertTrue(error.localizedDescription.contains("電話アプリ")) }
                do { _ = try await manager.readKeypadFile(path: file.path); XCTFail("Removed file read") }
                catch { XCTAssertTrue(error.localizedDescription.contains("電話アプリ")) }
                do { _ = try await manager.readKeypadPreview(file); XCTFail("Removed image exported") }
                catch { XCTAssertTrue(error.localizedDescription.contains("電話アプリ")) }
                do {
                    _ = try await manager.prepareKeypadChange(KeypadWritePlan(entries: [KeypadWriteEntry(file: file, data: local.data)]))
                    XCTFail("Removed target write prepared")
                } catch { XCTAssertTrue(error.localizedDescription.contains("電話アプリ")) }
            }
        }
        XCTAssertEqual(try FileBackupStore(root: root.appendingPathComponent("Backups")).list().records.count, 0)
        XCTAssertEqual(try FileBackupStore.Snapshot(path: local.file.path), local.file.snapshot)
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeypadTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func image(red: CGFloat, width: Int = 20, height: Int = 30) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func fixtures(_ root: URL, names: [String] = ["other-1---white.png", "other-2-A B C--mask.png"],
                          width: Int = 20, height: Int = 30) throws -> [KeypadWriteEntry] {
        let old = try image(red: 1, width: width, height: height), new = try image(red: 0, width: width, height: height)
        return try names.map { name in
            let path = root.appendingPathComponent(name).path
            try old.write(to: URL(fileURLWithPath: path))
            let file = KeypadCacheFile(path: path, name: try XCTUnwrap(KeypadAssetName(name)), snapshot: try FileBackupStore.Snapshot(path: path),
                                       directory: try FileBackupStore.Snapshot(path: root.path), width: width, height: height)
            return KeypadWriteEntry(file: file, data: new)
        }
    }
    private func backup(_ entry: KeypadWriteEntry, store: FileBackupStore) throws -> FileBackupStore.Backup {
        let url = URL(fileURLWithPath: entry.file.path)
        return try store.prepare(operation: .replaceKeypad(path: url.path), source: url, destination: url)
    }
    private func write(_ entry: KeypadWriteEntry) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: entry.file.path))
        defer { try? handle.close() }
        try handle.write(contentsOf: entry.data)
        try handle.truncate(atOffset: UInt64(entry.data.count))
        try handle.synchronize()
    }
    private func zip(_ root: URL, entries: [(String, Data)], symlink: Bool = false) throws -> URL {
        let spec = root.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: entries.map { ["name": $0.0, "data": $0.1.base64EncodedString()] }).write(to: spec)
        defer { try? FileManager.default.removeItem(at: spec) }
        let url = root.appendingPathComponent(UUID().uuidString + ".passthm")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
        import sys,json,zipfile,base64
        with zipfile.ZipFile(sys.argv[2],'w') as z:
            for e in json.load(open(sys.argv[1])):
                info=zipfile.ZipInfo(e['name'])
                info.create_system=3
                info.external_attr=(0o120777 if sys.argv[3]=='true' else 0o100644)<<16
                z.writestr(info,base64.b64decode(e['data']))
        """, spec.path, url.path, String(symlink)]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RunnerError("Keypad fixture failed") }
        return url
    }
}
