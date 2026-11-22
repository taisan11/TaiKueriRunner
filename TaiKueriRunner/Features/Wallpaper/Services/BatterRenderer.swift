import Foundation

enum BatterRenderer {
    // Operate on a bounded virtual tree, never on user/device filesystem paths.
    static func render(_ zip: WallpaperZIP, template: BatterTemplate, selections: BatterSelections) throws -> [String: Data] {
        try template.validate()
        let entries = zip.entries.filter { !$0.directory && $0.name.hasPrefix(template.root) && !$0.name.split(separator: "/").contains("__MACOSX") }
        guard entries.count < 9000, entries.reduce(0, { $0 + $1.size }) <= WallpaperImporter.maximumBytes else {
            throw RunnerError(localized: "Batter全体は256 MiB・9,000ファイル未満までです。")
        }
        var files: [String: Data] = [:]
        for entry in entries { files[String(entry.name.dropFirst(template.root.count))] = try zip.contents(entry) }
        for option in template.identifiedOptions {
            try Task.checkCancellation()
            let value = selections.values[option.id] ?? option.initialValue
            switch option.type {
            case "replace":
                guard let data = selections.replacements[option.id] else {
                    if option.required { throw RunnerError(localized: "ファイルを選択してください: \(String(describing: option.label))") }
                    continue
                }
                guard data.count <= WallpaperZIP.maximumFileBytes else { throw RunnerError(localized: "差し替えファイルは64 MiBまでです。") }
                let matches = try matched(option.files, in: files)
                guard !matches.isEmpty else { throw RunnerError(localized: "差し替え先が見つかりません: \(String(describing: option.label))") }
                for path in matches { files[path] = data }
            case "remove":
                guard case .bool(let checked) = value else { throw RunnerError(localized: "チェック項目の値が不正です。") }
                if checked != option.inverted {
                    let paths = try matched(option.files, in: files)
                    if option.identifier != nil {
                        for path in paths { files[path] = try BatterXML.edit(files[path]!, option: option, value: nil) }
                    } else {
                        for path in paths { files.removeValue(forKey: path) }
                    }
                }
            case "picker":
                let selected = selections.picked[option.id] ?? option.initialSelection
                guard selected.allSatisfy({ option.options.indices.contains($0) }),
                      option.allow_multiple_selection || selected.count == 1 else { throw RunnerError(localized: "選択項目が不正です: \(String(describing: option.label))") }
                let kept = try Set(matched(selected.sorted().flatMap { option.options[$0].files }, in: files))
                let removed = try matched(option.options.indices.filter { !selected.contains($0) }.flatMap { option.options[$0].files }, in: files)
                for path in removed where !kept.contains(path) { files.removeValue(forKey: path) }
                if option.rename, let index = selected.first {
                    // Capture all sources first, then rename atomically (including directories).
                    var moved: [String: Data] = [:], old = Set<String>()
                    for (source, destination) in zipPairs(option.options[index].files, option.names) {
                        guard !source.contains("*"), !source.contains("?"), !source.contains("[") else {
                            throw RunnerError(localized: "名前変更元のワイルドカードには対応していません。")
                        }
                        let paths = try matched([source], in: files)
                        guard !paths.isEmpty else { throw RunnerError(localized: "名前変更元がありません: \(String(describing: source))") }
                        for path in paths {
                            let target = destination + path.dropFirst(source.count)
                            try BatterTemplate.validatePath(target)
                            guard moved[target] == nil else { throw RunnerError(localized: "名前変更先が重複しています。") }
                            moved[target] = files[path]
                            old.insert(path)
                        }
                    }
                    for path in old { files.removeValue(forKey: path) }
                    for (path, data) in moved {
                        guard files[path] == nil else { throw RunnerError(localized: "Batterの名前変更先に別のファイルがあります。") }
                        files[path] = data
                    }
                }
            case "set":
                let converted = try converted(value, option: option)
                let paths = try matched(option.files, in: files)
                guard !paths.isEmpty else { throw RunnerError(localized: "値の変更先が見つかりません: \(String(describing: option.label))") }
                for path in paths {
                    let data = files[path]!
                    guard data.count <= 1_048_576 else { throw RunnerError(localized: "編集するテキスト・メタデータは1 MiBまでです。") }
                    let ext = (path as NSString).pathExtension.lowercased()
                    if ext == "caml" || ext == "xml" {
                        files[path] = try BatterXML.edit(data, option: option, value: converted)
                    } else if ext == "plist" {
                        var format = PropertyListSerialization.PropertyListFormat.binary
                        let original = try PropertyListSerialization.propertyList(from: data, format: &format)
                        var changed = 0
                        func update(_ input: Any, depth: Int) throws -> Any {
                            guard depth < 64 else { throw RunnerError(localized: "plistが深すぎます。") }
                            if var dict = input as? [String: Any] {
                                for (key, child) in dict {
                                    if key == option.key { dict[key] = converted.propertyList; changed += 1 }
                                    else { dict[key] = try update(child, depth: depth + 1) }
                                }
                                return dict
                            }
                            if let array = input as? [Any] { return try array.map { try update($0, depth: depth + 1) } }
                            return input
                        }
                        let updated = try update(original, depth: 0)
                        guard changed > 0 else { throw RunnerError(localized: "plistのキーが見つかりません: \(String(describing: option.label))") }
                        files[path] = try PropertyListSerialization.data(fromPropertyList: updated, format: format, options: 0)
                    } else {
                        guard let text = String(data: data, encoding: .utf8), let key = option.key, text.contains(key) else {
                            throw RunnerError(localized: "テキストの置換対象が見つかりません: \(String(describing: option.label))")
                        }
                        files[path] = Data(text.replacingOccurrences(of: key, with: converted.text).utf8)
                    }
                }
            default: throw RunnerError(localized: "未対応のBatter設定です。")
            }
            try validateTree(files)
        }
        return Dictionary(uniqueKeysWithValues: files.map { (template.root + $0.key, $0.value) })
    }

    private static func zipPairs(_ a: [String], _ b: [String]) -> [(String, String)] { Array(zip(a, b)) }

    static func matched(_ patterns: [String], in files: [String: Data]) throws -> [String] {
        guard patterns.count * files.count <= 2_000_000 else { throw RunnerError(localized: "Batterのワイルドカード照合数が上限を超えています。") }
        var result = Set<String>()
        for pattern in patterns {
            try Task.checkCancellation()
            try validatePattern(pattern)
            for name in files.keys {
                if matches(pattern, path: name) { result.insert(name) }
            }
        }
        return result.sorted()
    }

    static func validatePattern(_ pattern: String) throws {
        try BatterTemplate.validatePath(pattern)
        guard !pattern.contains("[") && !pattern.contains("]") else { throw RunnerError(localized: "Batterの[文字クラス]には対応していません。") }
    }

    // Memoized path matching and iterative component matching avoid regex
    // backtracking on attacker-controlled wildcard patterns.
    static func matches(_ pattern: String, path: String, descendants: Bool = true) -> Bool {
        let patterns = pattern.split(separator: "/").map(String.init), parts = path.split(separator: "/").map(String.init)
        var memo: [Int: Bool] = [:]
        func component(_ pattern: String, _ value: String) -> Bool {
            let p = Array(pattern), v = Array(value)
            var i = 0, j = 0, star: Int?, restart = 0
            while j < v.count {
                if i < p.count, p[i] == "?" || (p[i] != "*" && p[i] == v[j]) { i += 1; j += 1 }
                else if i < p.count, p[i] == "*" { star = i; i += 1; restart = j }
                else if let saved = star { restart += 1; j = restart; i = saved + 1 }
                else { return false }
            }
            while i < p.count, p[i] == "*" { i += 1 }
            return i == p.count
        }
        func match(_ p: Int, _ n: Int) -> Bool {
            let key = p * (parts.count + 1) + n
            if let cached = memo[key] { return cached }
            let result: Bool
            if p == patterns.count { result = descendants || n == parts.count }
            else if patterns[p] == "**" { result = match(p + 1, n) || (n < parts.count && match(p, n + 1)) }
            else { result = n < parts.count && component(patterns[p], parts[n]) && match(p + 1, n + 1) }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    private static func validateTree(_ files: [String: Data]) throws {
        guard files.count < 9000, files.values.reduce(0, { $0 + $1.count }) <= WallpaperImporter.maximumBytes else {
            throw RunnerError(localized: "カスタマイズ後のBatterが256 MiB・9,000ファイルの上限を超えています。")
        }
        var seen = Set<String>()
        for (name, data) in files {
            try BatterTemplate.validatePath(name)
            guard data.count <= WallpaperZIP.maximumFileBytes,
                  seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw RunnerError(localized: "カスタマイズ後のファイルに重複またはサイズ超過があります。")
            }
        }
        for name in seen {
            let parts = name.split(separator: "/")
            for count in 1..<parts.count where seen.contains(parts.prefix(count).joined(separator: "/")) {
                throw RunnerError(localized: "カスタマイズ後のファイルとフォルダが衝突しています。")
            }
        }
    }

    static func converted(_ value: BatterValue, option: BatterOption) throws -> BatterValue {
        if option.setter_type == "toggle" {
            guard case .bool(let selected) = value else { throw RunnerError(localized: "トグルの値が不正です。") }
            let on = selected != option.inverted
            return (on ? option.toggle_on_value : option.toggle_off_value) ?? .bool(on)
        }
        if option.setter_type == "color_picker" {
            let components = value.text.split(separator: " ").compactMap { Double($0) }
            guard components.count == 3 || components.count == 4,
                  components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw RunnerError(localized: "色は0〜1のRGB / RGBA値で指定してください。") }
            return value
        }
        guard value.text.utf8.count <= 4096, value.text.unicodeScalars.allSatisfy({
            $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32
        }) else { throw RunnerError(localized: "設定値が長すぎるか、制御文字を含みます。") }
        if option.setter_type == "slider" || option.value_type == "integer" || option.value_type == "float" {
            let parsed = try BatterNumbers(value.text)
            var values = parsed.values
            if option.setter_type == "slider" {
                let slider = try BatterSlider(option)
                guard values.count == slider.low.count else { throw RunnerError(localized: "スライダーの成分数が不正です。") }
                for index in values.indices {
                    let low = slider.low[index], high = slider.high[index], step = slider.steps[index]
                    guard (low...high).contains(values[index]) else { throw RunnerError(localized: "スライダーの範囲外の値です: \(String(describing: option.label))") }
                    values[index] = min(high, max(low, low + ((values[index] - low) / step).rounded() * step))
                }
            } else {
                for (bound, lower) in [(option.min_value, true), (option.max_value, false)] {
                    if let bound {
                        let numbers = try BatterNumbers(bound.text).values
                        guard numbers.count == 1 || numbers.count == values.count else { throw RunnerError(localized: "数値の範囲の成分数が一致しません。") }
                        for index in values.indices {
                            let limit = numbers[numbers.count == 1 ? 0 : index]
                            guard lower ? values[index] >= limit : values[index] <= limit else {
                                throw RunnerError(localized: "数値が設定された範囲外です: \(String(describing: option.label))")
                            }
                        }
                    }
                }
            }
            guard values.allSatisfy(\.isFinite) else { throw RunnerError(localized: "有限な数値を入力してください。") }
            if option.value_type == "integer" {
                guard values.allSatisfy({ Int(exactly: $0) != nil }) else { throw RunnerError(localized: "整数を入力してください。") }
                if values.count == 1, parsed.tag == nil { return .integer(Int(values[0])) }
            }
            if values.count == 1, parsed.tag == nil { return .number(values[0]) }
            return .string(BatterNumbers.text(values, tag: parsed.tag))
        }
        return value
    }
}
