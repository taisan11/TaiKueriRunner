import XCTest
import ImageIO
import CoreGraphics
@testable import RunnerCore

final class KeypadExportTests: XCTestCase {
    func testSinglePNGPreservesExactOriginalBytesDimensionsAndSourceState() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, folder: "TelephonyUI-10", name: "other-1---white.png", width: 700, height: 900)
        let original = try Data(contentsOf: URL(fileURLWithPath: file.path))
        let staged = try await KeypadExport.stage(files: [file], archive: false, temporaryRoot: root, read: Self.read)
        XCTAssertEqual(staged.url.lastPathComponent, file.name.leaf)
        XCTAssertEqual(try Data(contentsOf: staged.url), original)
        let dimensions = try KeypadImage.pngDimensions(Data(contentsOf: staged.url))
        XCTAssertEqual(dimensions.0, 700); XCTAssertEqual(dimensions.1, 900)
        XCTAssertEqual(try FileBackupStore.Snapshot(path: file.path), file.snapshot)
        XCTAssertNotEqual(staged.url.path, file.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
    }

    func testPhoneArchivePreservesLocalesAndVariantsAndCanBeImportedAsTheme() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try [
            fixture(root, folder: "TelephonyUI-10", name: "en-1---white.png"),
            fixture(root, folder: "TelephonyUI-10", name: "en-1---mask.png"),
            fixture(root, folder: "TelephonyUI-10", name: "ru-2-А Б В Г--white-bold.png"),
            fixture(root, folder: "TelephonyUI-10", name: "other-2-A B C-hi-mask.png")
        ]
        let staged = try await KeypadExport.stage(files: files, archive: true, temporaryRoot: root, read: Self.read)
        XCTAssertEqual(staged.url.lastPathComponent, "Keypad-phone-images.zip")
        try StableFileReader.withFile(path: staged.url.path, maximumBytes: KeypadExport.maximumArchiveBytes) { handle, size in
            let zip = try WallpaperZIP(handle: handle, size: size)
            XCTAssertEqual(zip.entries.filter { !$0.directory }.count, files.count)
            for file in files {
                let name = "Data/" + (try KeypadExport.relativePath(file))
                let entry = try XCTUnwrap(zip.entries.first { $0.name == name })
                XCTAssertEqual(try zip.contents(entry), try Data(contentsOf: URL(fileURLWithPath: file.path)))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.appendingPathComponent("Images").path))
        XCTAssertEqual(try KeypadTheme.inspect(staged.url).keys, [.one, .two])
        for file in files { XCTAssertEqual(try FileBackupStore.Snapshot(path: file.path), file.snapshot) }
    }

    func testFailedReadDeletesOnlyItsWorkspaceAndNeverLeavesPartialArchive() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try [
            fixture(root, folder: "TelephonyUI-10", name: "en-1---white.png"),
            fixture(root, folder: "TelephonyUI-10", name: "en-2-A B C--white.png")
        ]
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            _ = try await KeypadExport.stage(files: files, archive: true, temporaryRoot: root) { file in
                if file.name.key == .two { throw RunnerError("Simulated read denial") }
                return try await Self.read(file)
            }
            XCTFail("Incomplete archive returned")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Simulated read denial")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        for file in files { XCTAssertEqual(try FileBackupStore.Snapshot(path: file.path), file.snapshot) }
    }

    func testChangedSourceAndMismatchedBytesAbortAndCleanUp() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, folder: "TelephonyUI-10", name: "other-1---mask.png")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            _ = try await KeypadExport.stage(files: [file], archive: false, temporaryRoot: root) { _ in Data() }
            XCTFail("Wrong size accepted")
        } catch {}
        try Data("changed externally".utf8).write(to: URL(fileURLWithPath: file.path))
        do {
            _ = try await KeypadExport.stage(files: [file], archive: false, temporaryRoot: root, read: Self.read)
            XCTFail("Changed source accepted")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try String(contentsOfFile: file.path, encoding: .utf8), "changed externally")
    }

    func testEmptyDuplicateAndCollidingTargetsAreRejectedBeforeReading() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(root, folder: "TelephonyUI-10", name: "en-1---white.png")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let b = try fixture(other, folder: "TelephonyUI-10", name: "en-1---white.png")
        for files in [[], [a, a], [a, b]] {
            do {
                _ = try await KeypadExport.stage(files: files, archive: true, temporaryRoot: root) { _ in
                    XCTFail("Invalid selection was read"); return Data()
                }
                XCTFail("Invalid selection accepted")
            } catch {}
        }
        do {
            _ = try await KeypadExport.stage(files: [a, b], archive: false, temporaryRoot: root) { _ in
                XCTFail("Multiple single PNGs were read"); return Data()
            }
            XCTFail("Multiple single PNGs accepted")
        } catch {}
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("KeypadExport-") })
    }

    func testCancellationAfterReadCleansPrivateCopyAndPreservesSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, folder: "TelephonyUI-10", name: "other-0-+--white.png")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let task = Task {
            try await KeypadExport.stage(files: [file], archive: true, temporaryRoot: root) { file in
                let data = try await Self.read(file)
                withUnsafeCurrentTask { $0?.cancel() }
                return data
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled export completed") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
        XCTAssertEqual(try FileBackupStore.Snapshot(path: file.path), file.snapshot)
    }

    func testCleanupDoesNotDeleteAnUnownedDirectory() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root, folder: "TelephonyUI-10", name: "other-1---white.png")
        let worker = KeypadLibraryWorker(files: FileAccessManager(backupRoot: root.appendingPathComponent("Backups")))
        await worker.closeExport(StagedDocumentPreview(url: URL(fileURLWithPath: file.path), directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testExportRejectsNonPhoneCacheVersionsBeforeReading() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["TelephonyUI-8", "TelephonyUI-9", "TelephonyUI-11"] {
            let file = try fixture(root, folder: folder, name: "other-1---white.png")
            do {
                _ = try await KeypadExport.stage(files: [file], archive: true, temporaryRoot: root) { _ in
                    XCTFail("Non-phone cache version was read")
                    return Data()
                }
                XCTFail("Non-phone cache version was exported")
            } catch {}
            XCTAssertEqual(try FileBackupStore.Snapshot(path: file.path), file.snapshot)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("KeypadExport-") })
    }

    private static func read(_ file: KeypadCacheFile) async throws -> Data {
        guard try FileBackupStore.Snapshot(path: file.path) == file.snapshot else { throw RunnerError("Changed source") }
        let data = try StableFileReader.read(path: file.path, maximumBytes: KeypadImage.maximumBytes) { $0 }
        guard try FileBackupStore.Snapshot(path: file.path) == file.snapshot else { throw RunnerError("Changed source") }
        return data
    }
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeypadExportTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func fixture(_ root: URL, folder: String, name: String, width: Int = 20, height: Int = 30) throws -> KeypadCacheFile {
        let directory = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let url = directory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return KeypadCacheFile(path: url.path, name: try XCTUnwrap(KeypadAssetName(name)), snapshot: try FileBackupStore.Snapshot(path: url.path),
            directory: try FileBackupStore.Snapshot(path: directory.path), width: width, height: height)
    }
}
