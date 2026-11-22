import Foundation

// A data-only format. No scripts, restore domains or expressions from a package
// are ever handed to a shell, interpreter or predicate evaluator.
enum BatterValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), integer(Int), bool(Bool)

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }

    var text: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .integer(let value): String(value)
        case .bool(let value): value ? "1" : "0"
        }
    }
    var boolean: Bool { if case .bool(let value) = self { value } else { false } }
    var propertyList: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .integer(let value): value
        case .bool(let value): value
        }
    }
}

struct BatterOption: Decodable, Equatable, Sendable, Identifiable {
    struct Choice: Decodable, Equatable, Sendable {
        let label: String
        let files: [String]
        var associated_preview: String?
    }
    var id: Int = 0
    let type: String
    let label: String
    var files: [String] = []
    var button_label: String?
    var allowed_files: String?
    var required: Bool = false
    var identifier: String?
    var use_ca_id: Bool = false
    var key: String?
    var setter_type: String?
    var value_type: String?
    var default_value: BatterValue?
    var min_value: BatterValue?
    var max_value: BatterValue?
    var step: BatterValue?
    var inverted: Bool = false
    var toggle_off_value: BatterValue?
    var toggle_on_value: BatterValue?
    var sets_opacity: Bool = false
    var options: [Choice] = []
    var allow_multiple_selection: Bool = false
    var rename: Bool = false
    var names: [String] = []
    var default_values: [Int] = []
    var associated_preview: String?

    // Defaults in Swift declarations are not used by synthesized Decodable.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        type = try c.decode(String.self, forKey: .type)
        label = try c.decode(String.self, forKey: .label)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        button_label = try c.decodeIfPresent(String.self, forKey: .button_label)
        allowed_files = try c.decodeIfPresent(String.self, forKey: .allowed_files)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        use_ca_id = try c.decodeIfPresent(Bool.self, forKey: .use_ca_id) ?? false
        key = try c.decodeIfPresent(String.self, forKey: .key)
        setter_type = try c.decodeIfPresent(String.self, forKey: .setter_type)
        value_type = try c.decodeIfPresent(String.self, forKey: .value_type)
        default_value = try c.decodeIfPresent(BatterValue.self, forKey: .default_value)
        min_value = try c.decodeIfPresent(BatterValue.self, forKey: .min_value)
        max_value = try c.decodeIfPresent(BatterValue.self, forKey: .max_value)
        step = try c.decodeIfPresent(BatterValue.self, forKey: .step)
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        toggle_off_value = try c.decodeIfPresent(BatterValue.self, forKey: .toggle_off_value)
        toggle_on_value = try c.decodeIfPresent(BatterValue.self, forKey: .toggle_on_value)
        sets_opacity = try c.decodeIfPresent(Bool.self, forKey: .sets_opacity) ?? false
        options = try c.decodeIfPresent([Choice].self, forKey: .options) ?? []
        allow_multiple_selection = try c.decodeIfPresent(Bool.self, forKey: .allow_multiple_selection) ?? false
        rename = try c.decodeIfPresent(Bool.self, forKey: .rename) ?? false
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        default_values = try c.decodeIfPresent([Int].self, forKey: .default_values) ?? []
        associated_preview = try c.decodeIfPresent(String.self, forKey: .associated_preview)
    }

    private enum Key: String, CodingKey {
        case type, label, files, button_label, allowed_files, required, identifier, use_ca_id, key, setter_type, value_type
        case default_value, min_value, max_value, step, inverted, toggle_off_value, toggle_on_value, sets_opacity
        case options, allow_multiple_selection, rename, names, default_values, associated_preview
    }

    var initialValue: BatterValue {
        default_value ?? (type == "remove" || setter_type == "toggle" ? .bool(false) :
            (setter_type == "color_picker" ? .string("1 1 1") : min_value ?? .string("0")))
    }
    var initialSelection: Set<Int> {
        if allow_multiple_selection { return Set(default_values) }
        guard let default_value else { return [0] }
        guard let value = Double(default_value.text), value.isFinite, value >= 0, value < Double(options.count),
              value.rounded() == value else { return [-1] }
        return [Int(value)]
    }
}

struct BatterTemplate: Decodable, Equatable, Sendable {
    let title: String
    let author: String
    let domain: String
    let format_version: BatterValue
    let options: [BatterOption]
    var description: String?
    var min_version: String?
    var max_version: String?
    var previews: [String]?
    var resources: [String]?
    var preview_layout: String?
    var banner_text: String?
    var root: String = ""

    private enum CodingKeys: String, CodingKey {
        case title, author, domain, format_version, options, description, min_version, max_version
        case previews, resources, preview_layout, banner_text
    }

    static func inspect(_ zip: WallpaperZIP, required: Bool) throws -> BatterTemplate? {
        let configs = zip.entries.filter {
            !$0.directory && ($0.name as NSString).lastPathComponent.lowercased() == "config.json" &&
            !$0.name.split(separator: "/").dropLast().contains(where: {
                $0.lowercased().contains("descriptor") || $0.lowercased() == "container" || $0 == "__MACOSX"
            })
        }
        guard !configs.isEmpty else {
            if required { throw RunnerError(localized: "Batterにconfig.jsonがありません。") }
            return nil
        }
        guard configs.count == 1, configs[0].size <= 1_048_576 else { throw RunnerError(localized: "Batterのconfig.jsonは1個・1 MiBまでです。") }
        var template: BatterTemplate
        do { template = try JSONDecoder().decode(Self.self, from: zip.contents(configs[0])) }
        catch { throw RunnerError(localized: "Batterのconfig.jsonを解析できません。\n\(String(describing: error.localizedDescription))") }
        template.root = String(configs[0].name.dropLast("config.json".count))
        try template.validate()
        return template
    }

    var identifiedOptions: [BatterOption] {
        options.enumerated().map { index, option in var option = option; option.id = index; return option }
    }

    func validate() throws {
        guard domain == "AppDomain-com.apple.PosterBoard" || domain == "com.apple.PosterBoard" else {
            throw RunnerError(localized: "このBatterの対象は\(String(describing: domain))です。PosterBoard壁紙向けだけに対応しています。")
        }
        guard ["1", "2", "1.0", "2.0"].contains(format_version.text), !title.isEmpty, !author.isEmpty,
              title.count <= 1000, author.count <= 1000, options.count <= 200 else {
            throw RunnerError(localized: "Batterの形式・ヘッダーが未対応または上限を超えています（format_version 1・2）。")
        }
        #if os(iOS)
        try validateVersion(ProcessInfo.processInfo.operatingSystemVersion)
        #endif
        for option in options {
            guard ["replace", "remove", "picker", "set"].contains(option.type), !option.label.isEmpty, option.label.count <= 1000 else {
                throw RunnerError(localized: "未対応のBatter設定です: \(String(describing: option.type))。bundle_idによる適用先の変更はできません。")
            }
            let paths = option.files + option.names + option.options.flatMap(\.files)
            guard paths.count <= 2000 else { throw RunnerError(localized: "Batterの対象ファイル指定が多すぎます。") }
            for path in paths { try BatterRenderer.validatePattern(path) }
            if option.type != "picker", option.files.isEmpty { throw RunnerError(localized: "Batter設定にfilesがありません: \(String(describing: option.label))") }
            if option.type == "remove", case .bool = option.initialValue {} else if option.type == "remove" {
                throw RunnerError(localized: "削除設定のdefault_valueはtrue / falseで指定してください。")
            }
            if option.type == "picker" {
                guard !option.options.isEmpty, option.options.count <= 200,
                      option.initialSelection.allSatisfy({ option.options.indices.contains($0) }),
                      !option.rename || (!option.allow_multiple_selection && !option.names.isEmpty &&
                        option.options.allSatisfy { $0.files.count == option.names.count }) else {
                    throw RunnerError(localized: "Batterのpicker設定が不正です: \(String(describing: option.label))")
                }
                for path in option.names + (option.rename ? option.options.flatMap(\.files) : [])
                    where path.contains("*") || path.contains("?") || path.contains("[") {
                    throw RunnerError(localized: "Batterの変更後の名前にはワイルドカードを使用できません: \(String(describing: path))")
                }
            }
            if option.type == "set" {
                guard ["textbox", "slider", "toggle", "color_picker"].contains(option.setter_type ?? ""),
                      let key = option.key, !key.isEmpty, key.count <= 1000,
                      option.value_type == nil || ["string", "integer", "float"].contains(option.value_type!) else {
                    throw RunnerError(localized: "Batterの値設定が不正です: \(String(describing: option.label))")
                }
                if option.setter_type == "slider" {
                    _ = try BatterSlider(option)
                }
                _ = try BatterRenderer.converted(option.initialValue, option: option)
            }
        }
        guard (previews?.count ?? 0) <= 20, (resources?.count ?? 0) <= 200,
              Set(previews ?? []).count == (previews?.count ?? 0) else {
            throw RunnerError(localized: "Batterの参考画像は20件、リソース指定は200件までです。")
        }
        for path in (resources ?? []) + (previews ?? []) { try BatterRenderer.validatePattern(path) }
    }

    func validateVersion(_ os: OperatingSystemVersion) throws {
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        for version in [min_version, max_version].compactMap({ $0 }) {
            guard version.count <= 32, version.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil else {
                throw RunnerError(localized: "BatterのiOSバージョン指定が不正です。")
            }
        }
        if let min_version, current.compare(min_version, options: .numeric) == .orderedAscending {
            throw RunnerError(localized: "このBatterにはiOS \(String(describing: min_version))以降が必要です。")
        }
        if let max_version {
            // Missing components represent zero, not an older spelling.
            let parts = max_version.split(separator: ".").map(String.init)
            let limit = (parts + Array(repeating: "0", count: max(0, 3 - parts.count))).joined(separator: ".")
            if current.compare(limit, options: .numeric) == .orderedDescending {
                throw RunnerError(localized: "このBatterの対応上限はiOS \(String(describing: max_version))です。")
            }
        }
    }

    func visiblePreviews(_ selections: BatterSelections) -> [String] {
        var visible = Set(previews ?? [])
        for option in identifiedOptions {
            if option.type == "remove", let preview = option.associated_preview,
               (selections.values[option.id] ?? option.initialValue).boolean != option.inverted {
                visible.remove(preview)
            }
            if option.type == "picker" {
                let selected = selections.picked[option.id] ?? option.initialSelection
                for index in option.options.indices where !selected.contains(index) {
                    if let preview = option.options[index].associated_preview { visible.remove(preview) }
                }
            }
        }
        return (previews ?? []).filter { visible.contains($0) }
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, path.utf8.count <= 4096, parts.count <= 64,
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") }) else {
            throw RunnerError(localized: "Batterに危険な相対パスがあります。")
        }
    }
}

struct BatterNumbers {
    let values: [Double]
    let tag: String?

    init(_ text: String) throws {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let opening = body.firstIndex(of: "(") {
            let name = String(body[..<opening])
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil, body.hasSuffix(")") else {
                throw RunnerError(localized: "数値のタグが不正です。")
            }
            tag = name
            body = String(body[body.index(after: opening)..<body.index(before: body.endIndex)])
        } else { tag = nil }
        let components = body.split(whereSeparator: \.isWhitespace)
        let numbers = components.compactMap { Double($0) }
        guard (1...4).contains(numbers.count), numbers.count == components.count, numbers.allSatisfy(\.isFinite) else {
            throw RunnerError(localized: "有限な数値を1〜4成分で指定してください。")
        }
        values = numbers
    }

    static func text(_ values: [Double], tag: String?) -> String {
        let text = values.map(String.init(describing:)).joined(separator: " ")
        return tag.map { $0 + "(" + text + ")" } ?? text
    }
}

struct BatterSlider {
    let low: [Double]
    let high: [Double]
    let steps: [Double]
    let initial: BatterNumbers

    init(_ option: BatterOption) throws {
        let initial = try BatterNumbers(option.initialValue.text)
        self.initial = initial
        func expanded(_ value: BatterValue?) throws -> [Double] {
            guard let value else { throw RunnerError(localized: "スライダーには最小値・最大値が必要です。") }
            let numbers = try BatterNumbers(value.text).values
            if numbers.count == 1 { return Array(repeating: numbers[0], count: initial.values.count) }
            guard numbers.count == initial.values.count else { throw RunnerError(localized: "スライダーの成分数が一致しません。") }
            return numbers
        }
        low = try expanded(option.min_value)
        high = try expanded(option.max_value)
        steps = try expanded(option.step ?? .integer(1))
        guard low.indices.allSatisfy({ low[$0] < high[$0] && steps[$0] > 0 &&
            (high[$0] - low[$0]).isFinite && ((high[$0] - low[$0]) / steps[$0]).isFinite }) else {
            throw RunnerError(localized: "スライダーの最小値・最大値・間隔が不正です: \(String(describing: option.label))")
        }
    }
}

struct BatterSelections: Sendable {
    var values: [Int: BatterValue] = [:]
    var picked: [Int: Set<Int>] = [:]
    var replacements: [Int: Data] = [:]
}
