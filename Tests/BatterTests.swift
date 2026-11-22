import XCTest
@testable import RunnerCore

final class BatterTests: XCTestCase {
    func testBatterMetadataAndCustomizationsAreAppliedBeforeIdentifierRemapping() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = "descriptors/example/"
        let content = prefix + "versions/1/contents/"
        let caml = content + "background.ca/main.caml"
        let options: [[String: Any]] = [
            ["type": "replace", "label": "Image", "required": true, "allowed_files": "PNG (*.png)", "files": [content + "bg.png"]],
            ["type": "set", "label": "Duration", "files": [caml], "identifier": "duration", "key": "duration", "setter_type": "slider",
             "min_value": 0.5, "max_value": 3, "step": 0.1, "default_value": 1],
            ["type": "set", "label": "Flip", "files": [caml], "identifier": "#2", "use_ca_id": true, "key": "geometryFlipped",
             "setter_type": "toggle", "inverted": true, "default_value": false],
            ["type": "remove", "label": "Hide", "files": [caml], "identifier": "remove", "default_value": true],
            ["type": "set", "label": "Color", "files": [caml], "identifier": "color", "key": "backgroundColor",
             "setter_type": "color_picker", "sets_opacity": true, "default_value": "1 0 0 0.5"]
        ]
        let xml = """
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0"><layer nuggetId="duration" duration="0"/>
        <layer id="#2" geometryFlipped="0"/><animation targetId="#2" geometryFlipped="0"/>
        <layer nuggetId="remove"/><layer nuggetId="color" backgroundColor="0 0 0"/></caml>
        """
        let archive = try package(root, options: options, files: [(caml, Data(xml.utf8)), (content + "bg.png", Data("old".utf8))])
        XCTAssertEqual(archive.template?.title, "Test Batter")
        XCTAssertEqual(archive.template?.author, "Test Author")
        let before = try Data(contentsOf: archive.url)
        var selections = BatterSelections()
        selections.replacements[0] = Data("new".utf8)
        selections.values[1] = .number(2.04)
        let staged = try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root, selections: selections)
        let output = try String(contentsOf: staged.appendingPathComponent("versions/1/contents/background.ca/main.caml"), encoding: .utf8)
        XCTAssertTrue(output.contains("duration=\"2.0\""))
        XCTAssertEqual(output.components(separatedBy: "geometryFlipped=\"1\"").count - 1, 2)
        XCTAssertFalse(output.contains("nuggetId=\"remove\""))
        XCTAssertTrue(output.contains("backgroundColor=\"1 0 0\""))
        XCTAssertTrue(output.contains("opacity=\"0.5\""))
        XCTAssertTrue(output.contains("xmlns=\"http://www.apple.com/CoreAnimation/1.0\""))
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("versions/1/contents/bg.png")), Data("new".utf8))
        let identifier = try String(contentsOf: staged.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier"), encoding: .utf8)
        XCTAssertNotEqual(identifier, "7420")
        XCTAssertNotNil(Int(identifier))
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("config.json").path))
    }

    func testRequiredReplacementAndInvalidUserValuesFailAndCleanStaging() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = "descriptors/example/versions/1/contents/bg.png"
        let archive = try package(root, options: [
            ["type": "replace", "label": "Required image", "required": true, "files": [target]]
        ], files: [(target, Data("old".utf8))])
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertThrowsError(try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root)) {
            XCTAssertTrue($0.localizedDescription.contains("Required image"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        for value in ["nan", "inf", "-1", "3", "not a number"] {
            let option = try option(["type": "set", "label": "Slider", "files": ["x"], "setter_type": "slider", "key": "x",
                                     "min_value": 0, "max_value": 2, "step": 0.1])
            XCTAssertThrowsError(try BatterRenderer.converted(.string(value), option: option))
        }
    }

    func testPickerDefaultsMultipleSelectionAndDirectoryRename() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "descriptors/example/versions/1/contents/"
        let options: [[String: Any]] = [
            ["type": "picker", "label": "Background", "rename": true, "names": [content + "background.ca"], "default_value": 1,
             "options": [["label": "A", "files": [content + "a.ca"]], ["label": "B", "files": [content + "b.ca"]]]],
            ["type": "picker", "label": "Extras", "allow_multiple_selection": true, "default_values": [0, 2],
             "options": (0..<3).map { ["label": "Item \($0)", "files": [content + "item\($0)"]] }]
        ]
        let files = [(content + "a.ca/main.caml", Data("A".utf8)), (content + "b.ca/.hidden", Data("B".utf8))] +
            (0..<3).map { (content + "item\($0)", Data(String($0).utf8)) }
        let archive = try package(root, options: options, files: files)
        let staged = try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root)
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("versions/1/contents/background.ca/.hidden")), Data("B".utf8))
        for absent in ["a.ca", "b.ca", "item1"] { XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("versions/1/contents/" + absent).path)) }
        for present in ["item0", "item2"] { XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("versions/1/contents/" + present).path)) }
    }

    func testRemoveInversionGlobRecursivePlistAndPlainText() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "descriptors/example/versions/1/contents/"
        let options: [[String: Any]] = [
            ["type": "remove", "label": "Keep", "files": [content + "**/*.tmp"], "inverted": true, "default_value": false],
            ["type": "set", "label": "Plist", "files": [content + "test.plist"], "setter_type": "textbox", "key": "duration",
             "value_type": "integer", "default_value": "2"],
            ["type": "set", "label": "Text", "files": [content + "text"], "setter_type": "textbox", "key": "TOKEN", "default_value": "new"]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: ["duration": 1, "nested": ["duration": 3, "keep": true]], format: .binary, options: 0)
        let archive = try package(root, options: options, files: [
            (content + "one.tmp", Data()), (content + "nested/two.tmp", Data()), (content + "test.plist", plist),
            (content + "text", Data("TOKEN TOKEN".utf8))
        ])
        let staged = try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("versions/1/contents/one.tmp").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("versions/1/contents/nested/two.tmp").path))
        let output = try PropertyListSerialization.propertyList(from: Data(contentsOf: staged.appendingPathComponent("versions/1/contents/test.plist")), format: nil) as! [String: Any]
        XCTAssertEqual(output["duration"] as? Int, 2)
        XCTAssertEqual((output["nested"] as? [String: Any])?["duration"] as? Int, 2)
        XCTAssertEqual((output["nested"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("versions/1/contents/text"), encoding: .utf8), "new new")
    }

    func testContainerTemplatesImportOnlyNewDescriptorsNotDeviceData() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "Container/" + WallpaperPaths.store + "/Extensions/"
        let prefix = base + "com.apple.WallpaperKit.CollectionsPoster/descriptors/old/"
        let archive = try package(root, options: [], files: [
            ("Container/Library/Preferences/com.apple.PosterBoard.plist", Data("never copy".utf8)),
            (base + "com.apple.WallpaperKit.CollectionsPoster/configurations/saved/data", Data("never copy".utf8))
        ], prefix: prefix, wrapper: "MyTemplate/")
        XCTAssertEqual(archive.template?.root, "MyTemplate/")
        XCTAssertEqual(archive.descriptors.count, 1)
        let staged = try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root)
        XCTAssertNotNil(UUID(uuidString: staged.lastPathComponent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Library").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("configurations").path))
    }

    func testUnsupportedDomainsVersionsTypesAndUnsafePathsAreExplicitlyRejected() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for extra: [String: Any] in [
            ["domain": "Sparserestore-/var/Managed Preferences"], ["domain": "AppDomain-com.apple.Preferences"],
            ["format_version": "3"], ["options": [["type": "bundle_id", "label": "Target"]]],
            ["options": [["type": "set", "label": "Unknown", "files": ["x"], "setter_type": "execute", "key": "x"]]],
            ["options": [["type": "picker", "label": "Invalid", "default_value": 1e100, "options": [["label": "A", "files": ["x"]]]]]]
        ] { XCTAssertThrowsError(try package(root, options: [], files: [], extra: extra)) }
        for path in ["../escape", "/absolute", "a/../escape", "a\\escape", "a//b", "a:escape", "a/\0"] {
            XCTAssertThrowsError(try package(root, options: [["type": "remove", "label": "Unsafe", "files": [path]]], files: []))
        }
    }

    func testXMLNeverResolvesEntitiesAndRejectsMissingIdentifiersAndUnsafeOffsets() throws {
        let option = try option(["type": "set", "label": "XML", "files": ["x.caml"], "identifier": "x", "key": "position", "setter_type": "textbox"])
        for xml in [
            "<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><x nuggetId=\"x\">&e;</x>",
            "<x nuggetId=\"other\"/>", "<x><broken></x>",
            "<x nuggetId=\"x\" nuggetOffset=\"__import__('os')\"/>"
        ] { XCTAssertThrowsError(try BatterXML.edit(Data(xml.utf8), option: option, value: .string("1 2"))) }
        let valid = Data("<x><layer nuggetId=\"x\" nuggetOffset=\"(2 * x + 10), (3 * y + 15)\" position=\"0 0\"/></x>".utf8)
        let output = try String(decoding: BatterXML.edit(valid, option: option, value: .string("2 3")), as: UTF8.self)
        XCTAssertTrue(output.contains("position=\"14.0 24.0\""))
        for equation in ["x/0", "x**2", "sin(x)", "x;1", String(repeating: "(", count: 100) + "x", "x+a"] {
            XCTAssertThrowsError(try BatterExpression.offset(equation, value: "1 2"))
        }
        XCTAssertThrowsError(try BatterExpression.offset("x", value: "1 notANumber"))
    }

    func testRenameCollisionsAndRemovedSelectedDescriptorCannotInstall() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "descriptors/example/versions/1/contents/"
        let collision = try package(root, options: [
            ["type": "picker", "label": "Collision", "rename": true, "names": [content + "existing"],
             "options": [["label": "One", "files": [content + "one"]]]]
        ], files: [(content + "one", Data()), (content + "existing", Data())])
        XCTAssertThrowsError(try WallpaperImporter.stage(collision.descriptors[0], from: collision, in: root))
        let removed = try package(root, options: [
            ["type": "remove", "label": "Remove wallpaper", "files": ["descriptors/example"], "default_value": true]
        ], files: [])
        XCTAssertThrowsError(try WallpaperImporter.stage(removed.descriptors[0], from: removed, in: root))
    }

    func testReplacementFiltersAndSizeAreEnforcedWithoutWritingOriginal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager(backupRoot: root.appendingPathComponent("Backups"))
        let path = root.appendingPathComponent("selected.png")
        try Data("bytes".utf8).write(to: path)
        let data = try await manager.readBatterReplacement(path, filter: "Images (*.png *.jpg)")
        XCTAssertEqual(data, Data("bytes".utf8))
        do { _ = try await manager.readBatterReplacement(path, filter: "Video (*.mp4)"); XCTFail("Wrong type accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), Data("bytes".utf8))
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: UInt64(WallpaperZIP.maximumFileBytes + 1))
        try handle.close()
        do { _ = try await manager.readBatterReplacement(path, filter: nil); XCTFail("Oversized replacement accepted") } catch {}
    }

    func testZipExtensionUsesConfigAndChangedArchiveCannotStage() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try package(root, options: [], files: [])
        let renamed = archive.url.deletingPathExtension().appendingPathExtension("zip")
        try FileManager.default.copyItem(at: archive.url, to: renamed)
        XCTAssertNotNil(try WallpaperImporter.inspect(renamed).template)
        var bytes = try Data(contentsOf: archive.url)
        bytes.append(0)
        try bytes.write(to: archive.url)
        XCTAssertThrowsError(try WallpaperImporter.stage(archive.descriptors[0], from: archive, in: root))
    }

    func testVectorSlidersAndTaggedValuesPreserveComponentsAndBounds() throws {
        let option = try option(["type": "set", "label": "Position", "files": ["x.caml"], "setter_type": "slider", "key": "position",
                                 "identifier": "x", "min_value": "-10 -20", "max_value": "10 20", "step": "0.5 1",
                                 "default_value": "scale(0 0)", "value_type": "float"])
        let slider = try BatterSlider(option)
        XCTAssertEqual(slider.low, [-10, -20])
        XCTAssertEqual(slider.high, [10, 20])
        XCTAssertEqual(try BatterRenderer.converted(.string("scale(2.2 3.3)"), option: option), .string("scale(2.0 3.0)"))
        XCTAssertThrowsError(try BatterRenderer.converted(.string("1"), option: option))
        XCTAssertThrowsError(try BatterRenderer.converted(.string("0 100"), option: option))
        let integer = try self.option(["type": "set", "label": "Integer", "files": ["x.plist"], "setter_type": "textbox",
                                       "key": "x", "value_type": "integer"])
        XCTAssertEqual(try BatterRenderer.converted(.string("7"), option: integer), .integer(7))
        XCTAssertThrowsError(try BatterRenderer.converted(.string("7.5"), option: integer))
    }

    func testWildcardMatchingIsBoundedAndPreviewVisibilityUsesSelections() throws {
        XCTAssertTrue(BatterRenderer.matches("a/**/b?.png", path: "a/dir/other/b1.png"))
        XCTAssertTrue(BatterRenderer.matches("a/**/b?.png", path: "a/b1.png"))
        XCTAssertTrue(BatterRenderer.matches("a/*", path: "a/.hidden/child"))
        XCTAssertFalse(BatterRenderer.matches("a/*.png", path: "a/sub/b.png"))
        XCTAssertFalse(BatterRenderer.matches(String(repeating: "*a", count: 100) + "b", path: String(repeating: "a", count: 1000)))
        XCTAssertThrowsError(try BatterRenderer.validatePattern("a/[ab]"))
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try package(root, options: [
            ["type": "remove", "label": "Preview", "files": ["descriptors/example/versions/1/contents/.hidden"],
             "default_value": true, "associated_preview": "preview.png"]
        ], files: [], extra: ["previews": ["preview.png"], "resources": ["*.png"]])
        XCTAssertEqual(archive.template?.visiblePreviews(BatterSelections()), [])
        var selections = BatterSelections()
        selections.values[0] = .bool(false)
        XCTAssertEqual(archive.template?.visiblePreviews(selections), ["preview.png"])
    }

    func testVersionLimitsAndHeaderValidation() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try package(root, options: [], files: [], extra: ["min_version": "18.0", "max_version": "27.2"])
        let template = try XCTUnwrap(archive.template)
        XCTAssertNoThrow(try template.validateVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)))
        XCTAssertThrowsError(try template.validateVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 9, patchVersion: 0)))
        XCTAssertThrowsError(try template.validateVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 1)))
        let malformed = try package(root, options: [], files: [], extra: ["min_version": "not a version"])
        XCTAssertThrowsError(try malformed.template?.validateVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)))
        XCTAssertThrowsError(try package(root, options: [], files: [], extra: ["previews": ["a.png", "a.png"]]))
        XCTAssertThrowsError(try package(root, options: [
            ["type": "remove", "label": "Invalid bool", "files": ["descriptors/example"], "default_value": "yes"]
        ], files: []))
    }

    func testEmbeddedPreviewMustBeDeclaredAsAResource() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4ZkAAAAASUVORK5CYII="))
        let archive = try package(root, options: [], files: [("preview.png", image)], extra: ["previews": ["preview.png"], "resources": ["*.png"]])
        XCTAssertNotNil(try WallpaperImporter.batterPreview("preview.png", archive: archive))
        XCTAssertNil(try WallpaperImporter.batterPreview("../preview.png", archive: archive))
        let undeclared = try package(root, options: [], files: [("preview.png", image)], extra: ["previews": ["preview.png"]])
        XCTAssertNil(try WallpaperImporter.batterPreview("preview.png", archive: undeclared))
    }

    private func option(_ object: [String: Any]) throws -> BatterOption {
        try JSONDecoder().decode(BatterOption.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatterTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func package(_ root: URL, options: [[String: Any]], files: [(String, Data)],
                         prefix: String = "descriptors/example/", wrapper: String = "", extra: [String: Any] = [:]) throws -> WallpaperArchive {
        var config: [String: Any] = ["title": "Test Batter", "author": "Test Author", "domain": "AppDomain-com.apple.PosterBoard",
                                     "format_version": "2", "options": options]
        config.merge(extra) { _, new in new }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["test": true], format: .binary, options: 0)
        let entries = [
            ("config.json", try JSONSerialization.data(withJSONObject: config)),
            (prefix + "providerInfo.plist", plist),
            (prefix + "com.apple.posterkit.provider.descriptor.identifier", Data("7420".utf8)),
            (prefix + "versions/1/contents/.hidden", Data("hidden".utf8))
        ] + files
        let spec = root.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: entries.map { ["name": wrapper + $0.0, "data": $0.1.base64EncodedString()] }).write(to: spec)
        defer { try? FileManager.default.removeItem(at: spec) }
        let url = root.appendingPathComponent(UUID().uuidString + ".batter")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
        import sys,json,zipfile,base64
        with zipfile.ZipFile(sys.argv[2],'w',compression=zipfile.ZIP_DEFLATED) as z:
            for e in json.load(open(sys.argv[1])):
                z.writestr(e['name'],base64.b64decode(e['data']))
        """, spec.path, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RunnerError("Batter fixture creation failed") }
        return try WallpaperImporter.inspect(url)
    }
}
