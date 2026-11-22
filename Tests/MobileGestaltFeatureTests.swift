import XCTest
@testable import RunnerCore

final class MobileGestaltFeatureTests: XCTestCase {
    func testEveryFeatureUsesVerifiedKeysAndUniqueIdentifiers() {
        let features = MobileGestaltFeature.all
        XCTAssertEqual(Set(features.map(\.id)).count, features.count)
        for feature in features {
            XCTAssertFalse(feature.fields.isEmpty, feature.id)
            XCTAssertEqual(Set(feature.fields.map(\.path)).count, feature.fields.count, feature.id)
            for field in feature.fields {
                XCTAssertEqual(MGKeyCatalog.names[field.key], field.name, "\(feature.id): \(field.key)")
            }
            for choice in feature.choices { XCTAssertEqual(choice.values.count, feature.fields.count, feature.id) }
        }
    }

    func testToggleConversionPreservesBooleanAndIntegerStorage() throws {
        for feature in MobileGestaltFeature.all where feature.choices.map(\.id) == ["off", "on"] {
            for value: PropertyListValue in [.boolean(false), .integer("0")] {
                var document = try fixture(Dictionary(uniqueKeysWithValues: feature.fields.map { ($0.key, value) }))
                let original = document.original
                XCTAssertTrue(feature.isAvailable(in: document), feature.id)
                try feature.stage(choice: "on", in: &document)
                XCTAssertEqual(feature.selection(in: document), "on")
                for field in feature.fields { XCTAssertEqual(try document.value(at: field.path).typeName, value.typeName) }
                XCTAssertEqual(try document.value(at: [.key("CacheData")]), .data(Data([1, 2, 3])))
                try feature.stage(choice: "off", in: &document)
                XCTAssertTrue(document.changes.isEmpty)
                XCTAssertEqual(try document.encoded(), original)
            }
        }
    }

    func testWrongTypedSettingsAreNotEditableAndMissingKeysAreAddedOnlyWhenStaged() throws {
        let feature = MobileGestaltFeature.bootChime
        let key = feature.fields[0].key
        for value: PropertyListValue in [.string("1"), .integer("2"), .real(1), .data(Data()), .array([])] {
            var document = try fixture([key: value])
            let original = document.root
            XCTAssertFalse(MobileGestaltFeature.available(in: document).contains { $0.id == feature.id })
            XCTAssertThrowsError(try feature.stage(choice: "on", in: &document))
            XCTAssertEqual(document.root, original)
        }
        var missing = try MobileGestaltDocument(path: "/copy.plist", data: PropertyListValue.dictionary([
            key: .boolean(false), "CacheExtra": .dictionary([:])
        ]).encode(format: .xml))
        XCTAssertTrue(feature.isAvailable(in: missing))
        XCTAssertTrue(feature.needsKeyAddition(in: missing))
        XCTAssertEqual(try feature.summary(in: missing), "未設定（キーなし）")
        XCTAssertTrue(missing.changes.isEmpty)
        try feature.stage(choice: "on", in: &missing)
        XCTAssertEqual(try missing.value(at: feature.fields[0].path), .integer("1"))
        XCTAssertEqual(try missing.value(at: [.key(key)]), .boolean(false))
        XCTAssertEqual(try feature.summary(in: missing, original: true), "未設定（キーなし）")
        try feature.reset(in: &missing)
        XCTAssertTrue(missing.changes.isEmpty)
        XCTAssertNil(try missing.valueIfPresent(at: feature.fields[0].path))
    }

    func testMultiFieldWritesAreAtomicAndMixedValuesRemainEditable() throws {
        let feature = try feature("alwaysOnDisplay")
        let keys = feature.fields.map(\.key)
        var document = try fixture([keys[0]: .boolean(false), keys[1]: .string("invalid")])
        let original = document.root
        XCTAssertFalse(feature.isAvailable(in: document))
        XCTAssertThrowsError(try feature.stage(choice: "on", in: &document))
        XCTAssertEqual(document.root, original)
        document = try fixture([keys[0]: .boolean(false), keys[1]: .integer("1")])
        XCTAssertTrue(feature.isAvailable(in: document))
        XCTAssertNil(feature.selection(in: document))
        XCTAssertEqual(try feature.summary(in: document), "一部のみ有効")
        try feature.stage(choice: "on", in: &document)
        XCTAssertEqual(feature.selection(in: document), "on")
        XCTAssertEqual(MobileGestaltFeature.changed(in: document).map(\.id), [feature.id])
        try feature.reset(in: &document)
        XCTAssertTrue(document.changes.isEmpty)
    }

    func testPickerTextAndNumberEditsPreserveNeighborsAndFormat() throws {
        let layout = try feature("islandLayout"), name = try feature("modelName"), count = try feature("flipbookCount")
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            var document = try fixture([
                "oPeik/9e8lQWMszEjbPzng": .dictionary(["ArtworkDeviceSubType": .integer("9999"), "ArtworkDeviceProductDescription": .string("Original"), "other": .string("keep")]),
                "YlEtTtHlNesRBMal1CqRaA": .integer("0"), "qqrspu7CpuPdZwSDxNY+Fg": .integer("0")
            ], format: format)
            XCTAssertTrue(layout.isAvailable(in: document))
            XCTAssertNil(layout.selection(in: document))
            try layout.stage(choice: "2556", in: &document)
            try name.stage(input: "My Phone", in: &document)
            try count.stage(input: "3", in: &document)
            let changed = document.root
            XCTAssertThrowsError(try layout.stage(choice: "invalid", in: &document))
            for invalid in ["-1", "1.5", "9223372036854775808"] { XCTAssertThrowsError(try count.stage(input: invalid, in: &document)) }
            XCTAssertEqual(document.root, changed)
            let saved = try MobileGestaltDocument(path: document.path, data: document.encoded())
            XCTAssertEqual(saved.format, format)
            XCTAssertEqual(try saved.value(at: layout.fields[0].path), .integer("2556"))
            XCTAssertEqual(try saved.value(at: layout.fields[1].path), .integer("1"))
            XCTAssertEqual(try saved.value(at: name.fields[0].path), .string("My Phone"))
            XCTAssertEqual(try saved.value(at: count.fields[0].path), .integer("3"))
            XCTAssertEqual(try saved.value(at: [.key("CacheExtra"), .key("oPeik/9e8lQWMszEjbPzng"), .key("other")]), .string("keep"))
            try layout.reset(in: &document)
            XCTAssertEqual(try document.value(at: name.fields[0].path), .string("My Phone"))
        }
    }

    func testMainApplyRejectsRawEditorChanges() throws {
        let feature = MobileGestaltFeature.liquidGlass
        var document = try fixture([feature.fields[0].key: .boolean(false), "other": .string("original")])
        try feature.stage(choice: "on", in: &document)
        XCTAssertNoThrow(try MobileGestaltFeature.validateGuidedChanges(in: document))
        try document.set(.string("raw edit"), at: [.key("CacheExtra"), .key("other")])
        XCTAssertThrowsError(try MobileGestaltFeature.validateGuidedChanges(in: document))
    }

    func testExtendedFlagsRejectUnsupportedTypesAndAutomaticallyAddMissingKeys() throws {
        for feature in MobileGestaltFeature.extendedFeatures where feature.choices.map(\.id) == ["off", "on"] {
            for value: PropertyListValue in [.integer("2"), .integer("-1"), .string("1"), .real(1), .array([]), .dictionary([:]), .data(Data())] {
                var document = try fixture([feature.fields[0].key: value])
                let root = document.root
                XCTAssertFalse(feature.isAvailable(in: document), feature.id)
                XCTAssertThrowsError(try feature.stage(choice: "on", in: &document), feature.id)
                XCTAssertEqual(document.root, root, feature.id)
                XCTAssertTrue(document.changes.isEmpty, feature.id)
            }
            var missing = try fixture([:])
            XCTAssertTrue(feature.isAvailable(in: missing), feature.id)
            try feature.stage(choice: "on", in: &missing)
            XCTAssertEqual(try missing.value(at: feature.fields[0].path), .integer("1"), feature.id)
            try feature.reset(in: &missing)
            XCTAssertTrue(missing.changes.isEmpty, feature.id)
        }
    }

    func testAllFeaturesCanAddTheirKeysAndResetForBothFormats() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            for feature in MobileGestaltFeature.all {
                var document = try fixture([:], format: format)
                let original = document.root
                XCTAssertNil(feature.editingIssue(in: document), feature.id)
                XCTAssertTrue(feature.needsKeyAddition(in: document), feature.id)
                XCTAssertTrue(document.changes.isEmpty)
                switch feature.control {
                case .toggle: try feature.stage(choice: "on", in: &document)
                case .picker: try feature.stage(choice: XCTUnwrap(feature.choices.first?.id), in: &document)
                case .text: try feature.stage(input: "Custom", in: &document)
                case .number: try feature.stage(input: "3", in: &document)
                }
                XCTAssertFalse(feature.needsKeyAddition(in: document), feature.id)
                XCTAssertEqual(document.changes.count, feature.fields.count, feature.id)
                XCTAssertNoThrow(try MobileGestaltFeature.validateGuidedChanges(in: document), feature.id)
                let saved = try MobileGestaltDocument(path: document.path, data: document.encoded())
                XCTAssertEqual(saved.format, format)
                for field in feature.fields { XCTAssertEqual(try saved.value(at: field.path), try document.value(at: field.path)) }
                XCTAssertEqual(try saved.value(at: [.key("CacheData")]), .data(Data([1, 2, 3])))
                try feature.reset(in: &document)
                XCTAssertEqual(document.root, original, feature.id)
                XCTAssertTrue(document.changes.isEmpty, feature.id)
                XCTAssertEqual(try document.encoded(), document.original, feature.id)
            }
        }
    }

    func testAddedArtworkParentsArePrunedWithoutRemovingOtherFeatures() throws {
        let layout = try feature("islandLayout"), name = try feature("modelName")
        var document = try MobileGestaltDocument(path: "/copy.plist", data: PropertyListValue.dictionary([
            "CacheData": .data(Data([1, 2, 3]))
        ]).encode(format: .binary))
        let original = document.root
        try layout.stage(choice: "2556", in: &document)
        try name.stage(input: "Custom", in: &document)
        try layout.reset(in: &document)
        XCTAssertEqual(try document.value(at: name.fields[0].path), .string("Custom"))
        XCTAssertEqual(document.changes.count, 1)
        try name.reset(in: &document)
        XCTAssertEqual(document.root, original)
        XCTAssertTrue(document.changes.isEmpty)

        // A preexisting empty dictionary must survive reset as well.
        document = try fixture(["oPeik/9e8lQWMszEjbPzng": .dictionary([:])])
        let withArtwork = document.root
        try name.stage(input: "Custom", in: &document)
        try name.reset(in: &document)
        XCTAssertEqual(document.root, withArtwork)
    }

    func testPartialAdditionsPreserveExistingTypesAndSupportSharedDetailedEditing() throws {
        let feature = try feature("alwaysOnDisplay")
        var document = try fixture([feature.fields[0].key: .boolean(true)])
        let original = document.root
        try feature.stage(choice: "off", in: &document)
        XCTAssertEqual(try document.value(at: feature.fields[0].path), .boolean(false))
        XCTAssertEqual(try document.value(at: feature.fields[1].path), .integer("0"))
        XCTAssertEqual(document.changes.count, 2)
        // The detailed scalar editor shares the same draft, including added keys.
        try document.set(.integer("1"), at: feature.fields[1].path)
        XCTAssertEqual(try document.value(at: feature.fields[1].path), .integer("1"))
        XCTAssertNoThrow(try MobileGestaltFeature.validateGuidedChanges(in: document))
        try feature.reset(in: &document)
        XCTAssertEqual(document.root, original)
        XCTAssertTrue(document.changes.isEmpty)
    }

    func testAutoAdditionRejectsMalformedParentsAndUnknownPathsAtomically() throws {
        let layout = try feature("islandLayout")
        for root: PropertyListValue in [
            .dictionary(["CacheExtra": .string("do not replace")]),
            .dictionary(["CacheExtra": .dictionary(["oPeik/9e8lQWMszEjbPzng": .integer("1")])]),
            .dictionary(["CacheExtra": .dictionary(["YlEtTtHlNesRBMal1CqRaA": .string("invalid")])])
        ] {
            var document = try MobileGestaltDocument(path: "/copy.plist", data: root.encode(format: .binary))
            XCTAssertNotNil(layout.editingIssue(in: document))
            XCTAssertThrowsError(try layout.stage(choice: "2556", in: &document))
            XCTAssertEqual(document.root, root)
            XCTAssertTrue(document.changes.isEmpty)
        }
        var document = try fixture([:])
        let original = document.root
        XCTAssertThrowsError(try document.setFeatureValue(.boolean(true), at: [.key("CacheExtra"), .key("unknown")]))
        let name = try feature("modelName")
        XCTAssertThrowsError(try name.stage(input: String(repeating: "x", count: 1_048_577), in: &document))
        XCTAssertEqual(document.root, original)
        XCTAssertTrue(document.changes.isEmpty)
    }

    func testAllFeaturesRemainInCatalogWhenPlistIsUnavailable() throws {
        let catalog = MobileGestaltFeature.all.filter { $0.matches(search: "") }
        XCTAssertEqual(catalog.map(\.id), MobileGestaltFeature.all.map(\.id))
        for feature in catalog { XCTAssertNotNil(feature.editingIssue(in: nil), feature.id) }
        let invalid = try fixture([MobileGestaltFeature.bootChime.fields[0].key: .string("unsupported")])
        XCTAssertNotNil(MobileGestaltFeature.bootChime.editingIssue(in: invalid))
        XCTAssertTrue(catalog.contains { $0.id == MobileGestaltFeature.bootChime.id })
    }

    func testExtendedFieldsCanBeReviewedSavedAndResetWithoutChangingNeighbors() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            for feature in MobileGestaltFeature.extendedFeatures {
                let field = try XCTUnwrap(feature.fields.first)
                let initial: PropertyListValue
                switch field.kind {
                case .flag: initial = .integer("0")
                case .integer: initial = .integer("0")
                case .string: initial = .string("Original")
                }
                var document = try fixture([field.key: initial, "untouched": .array([.integer("1"), .string("keep")])], format: format)
                switch feature.control {
                case .toggle, .picker: try feature.stage(choice: "on", in: &document)
                case .text: try feature.stage(input: "Custom", in: &document)
                case .number: try feature.stage(input: "3", in: &document)
                }
                XCTAssertNoThrow(try MobileGestaltFeature.validateGuidedChanges(in: document), feature.id)
                XCTAssertEqual(MobileGestaltFeature.changed(in: document).map(\.id), [feature.id])
                let saved = try MobileGestaltDocument(path: document.path, data: document.encoded())
                XCTAssertEqual(saved.format, format)
                XCTAssertEqual(try saved.value(at: field.path).typeName, initial.typeName)
                XCTAssertEqual(try saved.value(at: field.path), try document.value(at: field.path))
                XCTAssertEqual(try saved.value(at: [.key("CacheExtra"), .key("untouched")]), .array([.integer("1"), .string("keep")]))
                XCTAssertEqual(try saved.value(at: [.key("CacheData")]), .data(Data([1, 2, 3])))
                try feature.reset(in: &document)
                XCTAssertTrue(document.changes.isEmpty, feature.id)
                XCTAssertEqual(try document.encoded(), document.original, feature.id)
            }
        }
    }

    func testFeatureSearchIncludesTechnicalNamesHashesCategoriesAndNestedFields() throws {
        let hdr = try feature("rearHDR"), model = try feature("modelName")
        for query in ["HDR", "背面", "RearFacingCameraHDRCapability", hdr.fields[0].key, "カメラ・写真・動画", "  HDR\n", "   "] {
            XCTAssertTrue(hdr.matches(search: query), query)
        }
        XCTAssertTrue(model.matches(search: "ArtworkDeviceProductDescription"))
        XCTAssertFalse(hdr.matches(search: "does-not-exist"))
    }

    @MainActor
    func testFeatureResetOnlyRestoresThatFeaturesReadBaseline() async throws {
        let model = MobileGestaltModel()
        let document = try fixture([MobileGestaltFeature.bootChime.fields[0].key: .boolean(true), MobileGestaltFeature.tapToWake.fields[0].key: .boolean(true)])
        await model.load { document }
        try model.stage(.bootChime, choice: "off")
        try model.stage(.tapToWake, choice: "off")
        try model.reset(.bootChime)
        let draft = try XCTUnwrap(model.document)
        XCTAssertEqual(MobileGestaltFeature.bootChime.selection(in: draft), "on")
        XCTAssertEqual(MobileGestaltFeature.tapToWake.selection(in: draft), "off")
        XCTAssertEqual(draft.changes.count, 1)
    }

    private func feature(_ id: String) throws -> MobileGestaltFeature {
        try XCTUnwrap(MobileGestaltFeature.all.first { $0.id == id })
    }

    private func fixture(_ extra: [String: PropertyListValue], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> MobileGestaltDocument {
        try MobileGestaltDocument(path: "/fixture.plist", data: PropertyListValue.dictionary([
            "CacheExtra": .dictionary(extra), "CacheData": .data(Data([1, 2, 3]))
        ]).encode(format: format))
    }
}
