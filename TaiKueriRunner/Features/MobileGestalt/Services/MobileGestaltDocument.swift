import Foundation
#if SWIFT_PACKAGE
import NativeBridge
#endif

enum MGKeyCatalog {
    static let revision = "db9cf77fa9d5330070b3dcb73fc1fd6a271fc421"
    static let names: [String: String] = TKMobileGestaltKeyNames()
    static func name(for key: String) -> String { names[key] ?? key }
}

enum PlistPathComponent: Hashable, Sendable {
    case key(String), index(Int)
    var label: String { switch self { case .key(let key): key; case .index(let index): "[\(index)]" } }
}

struct MobileGestaltEntry: Identifiable, Sendable {
    let path: [PlistPathComponent]
    let value: PropertyListValue
    var key: String { path.last?.label ?? "Root" }
    var name: String { MGKeyCatalog.name(for: key) }
    var id: String { path.map { switch $0 { case .key(let key): "k\(key.utf8.count):\(key)"; case .index(let index): "i\(index)" } }.joined(separator: "/") }
    var location: String { path.map(\.label).joined(separator: " → ") }
}

struct MobileGestaltDocument: Sendable {
    static let directory = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/"
    static let defaultPath = directory + "com.apple.MobileGestalt.plist"
    let path: String
    let original: Data
    let format: PropertyListSerialization.PropertyListFormat
    private(set) var root: PropertyListValue
    private let baseline: PropertyListValue
    private(set) var changes: [String: MobileGestaltEntry] = [:]

    init(path: String, data: Data) throws {
        let decoded = try PropertyListValue.decode(data)
        guard case .dictionary = decoded.value else { throw RunnerError(localized: "MobileGestaltのルートはDictionaryである必要があります。") }
        self.path = try FileRules.canonical(path)
        original = data; format = decoded.format; root = decoded.value; baseline = decoded.value
    }

    var formatName: String { format == .binary ? L("バイナリPlist") : "XML Plist" }

    func value(at path: [PlistPathComponent]) throws -> PropertyListValue {
        try Self.value(in: root, path: path[...])
    }

    func originalValue(at path: [PlistPathComponent]) throws -> PropertyListValue {
        try Self.value(in: baseline, path: path[...])
    }

    // Missing dictionary members can be added by a guided feature. A malformed
    // existing parent is an error, not a missing key that can be overwritten.
    func valueIfPresent(at path: [PlistPathComponent], original: Bool = false) throws -> PropertyListValue? {
        try Self.valueIfPresent(in: original ? baseline : root, path: path[...])
    }

    private static func valueIfPresent(in value: PropertyListValue, path: ArraySlice<PlistPathComponent>) throws -> PropertyListValue? {
        guard let first = path.first else { return value }
        switch (value, first) {
        case (.dictionary(let values), .key(let key)):
            guard let child = values[key] else { return nil }
            return try Self.valueIfPresent(in: child, path: path.dropFirst())
        case (.array(let values), .index(let index)) where values.indices.contains(index):
            return try Self.valueIfPresent(in: values[index], path: path.dropFirst())
        default: throw RunnerError(localized: "Plistのパスが無効です。既存の親の型は変更できません。")
        }
    }

    private static func value(in value: PropertyListValue, path: ArraySlice<PlistPathComponent>) throws -> PropertyListValue {
        guard let first = path.first else { return value }
        switch (value, first) {
        case (.dictionary(let values), .key(let key)):
            guard let child = values[key] else { throw RunnerError(localized: "キーが存在しません。") }
            return try Self.value(in: child, path: path.dropFirst())
        case (.array(let values), .index(let index)) where values.indices.contains(index):
            return try Self.value(in: values[index], path: path.dropFirst())
        default: throw RunnerError(localized: "Plistのパスが無効です。")
        }
    }

    func entries(at path: [PlistPathComponent] = [], search: String = "") throws -> [MobileGestaltEntry] {
        var result: [MobileGestaltEntry] = []
        func visit(_ value: PropertyListValue, path: [PlistPathComponent], recursive: Bool) {
            let children: [MobileGestaltEntry]
            switch value {
            case .dictionary(let values): children = values.map { MobileGestaltEntry(path: path + [.key($0.key)], value: $0.value) }
            case .array(let values): children = values.enumerated().map { MobileGestaltEntry(path: path + [.index($0.offset)], value: $0.element) }
            default: children = []
            }
            for entry in children {
                if !recursive || entry.name.localizedStandardContains(search) || entry.key.localizedStandardContains(search) || entry.value.summary.localizedStandardContains(search) {
                    result.append(entry)
                }
                if recursive { visit(entry.value, path: entry.path, recursive: true) }
            }
        }
        visit(try value(at: path), path: path, recursive: !search.isEmpty)
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    mutating func set(_ newValue: PropertyListValue, at path: [PlistPathComponent]) throws {
        let current = try value(at: path)
        guard !current.isContainer, current.typeName == newValue.typeName else { throw RunnerError(localized: "既存の値の型は変更できません。") }
        func replace(_ value: PropertyListValue, path: ArraySlice<PlistPathComponent>) throws -> PropertyListValue {
            guard let first = path.first else { return newValue }
            switch (value, first) {
            case (.dictionary(var values), .key(let key)):
                guard let child = values[key] else { throw RunnerError(localized: "キーが存在しません。") }
                values[key] = try replace(child, path: path.dropFirst()); return .dictionary(values)
            case (.array(var values), .index(let index)) where values.indices.contains(index):
                values[index] = try replace(values[index], path: path.dropFirst()); return .array(values)
            default: throw RunnerError(localized: "編集パスが無効です。")
            }
        }
        let updated = try replace(root, path: path[...])
        // Validate serialization before changing the editable draft.
        _ = try updated.encode(format: format)
        root = updated
        let entry = MobileGestaltEntry(path: path, value: newValue)
        if try valueIfPresent(at: path, original: true) == newValue { changes.removeValue(forKey: entry.id) }
        else { changes[entry.id] = entry }
    }

    mutating func setFeatureValue(_ value: PropertyListValue, at path: [PlistPathComponent]) throws {
        let field = try Self.featureField(at: path)
        if let original = try valueIfPresent(at: path, original: true) { _ = try field.normalized(original) }
        let encoded = try field.encoded(value, like: valueIfPresent(at: path))
        try replaceFeatureValue(encoded, at: path)
    }

    mutating func resetFeatureValue(at path: [PlistPathComponent]) throws {
        _ = try Self.featureField(at: path)
        try replaceFeatureValue(valueIfPresent(at: path, original: true), at: path)
    }

    private static func featureField(at path: [PlistPathComponent]) throws -> MobileGestaltFeature.Field {
        guard let field = MobileGestaltFeature.all.lazy.flatMap(\.fields).first(where: { $0.path == path }),
              MGKeyCatalog.names[field.key] == field.name else {
            throw RunnerError(localized: "自動追加は定義済みのMobileGestaltキーだけに対応しています。")
        }
        return field
    }

    private mutating func replaceFeatureValue(_ newValue: PropertyListValue?, at path: [PlistPathComponent]) throws {
        func replace(_ current: PropertyListValue?, original: PropertyListValue?, path: ArraySlice<PlistPathComponent>) throws -> PropertyListValue? {
            guard let first = path.first else { return newValue }
            guard case .key(let key) = first else { throw RunnerError(localized: "自動追加はDictionaryのキーだけに対応しています。") }
            var values: [String: PropertyListValue]
            if let current {
                guard case .dictionary(let dictionary) = current else { throw RunnerError(localized: "既存の親の型は変更できません。") }
                values = dictionary
            } else { values = [:] }
            let originals: [String: PropertyListValue]
            if case .dictionary(let dictionary) = original { originals = dictionary } else { originals = [:] }
            values[key] = try replace(values[key], original: originals[key], path: path.dropFirst())
            // Remove only empty parents created by this draft, never preexisting
            // dictionaries or a parent that still holds another feature's edit.
            return values.isEmpty && original == nil ? nil : .dictionary(values)
        }
        guard let updated = try replace(root, original: baseline, path: path[...]) else { throw RunnerError(localized: "ルートは削除できません。") }
        _ = try updated.encode(format: format)
        let original = try valueIfPresent(at: path, original: true)
        root = updated
        let id = MobileGestaltEntry(path: path, value: newValue ?? .string("")).id
        if let newValue, newValue != original { changes[id] = MobileGestaltEntry(path: path, value: newValue) }
        else { changes.removeValue(forKey: id) }
    }

    mutating func discardChanges() { root = baseline; changes.removeAll() }
    func encoded() throws -> Data { changes.isEmpty ? original : try root.encode(format: format) }
}
