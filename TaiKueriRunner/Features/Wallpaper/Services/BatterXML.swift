import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Parse and serialize XML as inert data. CAML is never instantiated or rendered.
enum BatterXML {
    private final class Node {
        let name: String
        var attributes: [String: String]
        var children: [Part] = []
        init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    }
    private enum Part { case node(Node), text(String) }
    private final class Reader: NSObject, XMLParserDelegate {
        var roots: [Node] = [], stack: [Node] = []
        var count = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 30_000, stack.count < 64, !Task.isCancelled else { parser.abortParsing(); return }
            let node = Node(name, attributes)
            if let parent = stack.last { parent.children.append(.node(node)) } else { roots.append(node) }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.children.append(.text(string)) }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            if let string = String(data: data, encoding: .utf8) { stack.last?.children.append(.text(string)) }
            else { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName: String, systemID: String?) -> Data? { nil }
    }

    static func edit(_ data: Data, option: BatterOption, value: BatterValue?) throws -> Data {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY"),
              let identifier = option.identifier, !identifier.isEmpty else {
            throw RunnerError(localized: "CAML / XMLはUTF-8・1 MiBまでで、identifierが必要です。DTD・実体宣言は使用できません。")
        }
        let parser = XMLParser(data: data), reader = Reader()
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse(), reader.roots.count == 1 else {
            try Task.checkCancellation()
            throw RunnerError(localized: "CAML / XMLを解析できません: \(String(describing: option.label))")
        }
        if let key = option.key {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_.:-]*$"#, options: .regularExpression) != nil,
                  !key.hasPrefix("xmlns") else { throw RunnerError(localized: "XML属性名が不正です。") }
        }
        var changed = 0
        func update(_ node: Node) throws -> Bool {
            try Task.checkCancellation()
            let direct = node.attributes[option.use_ca_id ? "id" : "nuggetId"] == identifier
            let target = option.use_ca_id && node.attributes["targetId"] == identifier
            if direct || target {
                changed += 1
                guard let value else { return false }
                var result = value.text
                if direct, let offset = node.attributes["nuggetOffset"] { result = try BatterExpression.offset(offset, value: result) }
                if option.setter_type == "color_picker" {
                    let colors = result.split(separator: " ").map(String.init)
                    result = colors.prefix(3).joined(separator: " ")
                    if option.sets_opacity || colors.count == 4 { node.attributes["opacity"] = colors.count == 4 ? colors[3] : "1" }
                }
                node.attributes[option.key!] = result
            }
            var children: [Part] = []
            for part in node.children {
                if case .node(let child) = part { if try update(child) { children.append(part) } }
                else { children.append(part) }
            }
            node.children = children
            return true
        }
        guard try update(reader.roots[0]) else { throw RunnerError(localized: "XML文書のルートは削除できません。") }
        guard changed > 0 else { throw RunnerError(localized: "XMLのidentifierが見つかりません: \(String(describing: option.label))") }
        func escaped(_ string: String, attribute: Bool = false) -> String {
            var result = string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if attribute {
                result = result.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
                    .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\t", with: "&#9;")
            }
            return result
        }
        func serialize(_ node: Node) -> String {
            let attributes = node.attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(escaped($0.value, attribute: true))\"" }.joined()
            let children = node.children.map { part in
                switch part { case .node(let child): serialize(child); case .text(let text): escaped(text) }
            }.joined()
            return "<\(node.name)\(attributes)>\(children)</\(node.name)>"
        }
        let output = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + serialize(reader.roots[0])).utf8)
        guard output.count <= 1_048_576 else { throw RunnerError(localized: "編集後のXMLが1 MiBを超えています。") }
        return output
    }
}

// Small bounded arithmetic grammar, not eval(). Supports x/y/z/a, numbers,
// parentheses, unary signs and + - * / %. Function calls and code are rejected.
enum BatterExpression {
    static func offset(_ expression: String, value: String) throws -> String {
        let components = value.split(separator: " ")
        let values = components.compactMap { Double($0) }
        guard values.count == components.count, (1...4).contains(values.count), values.allSatisfy(\.isFinite), expression.count <= 1000 else {
            throw RunnerError(localized: "nuggetOffsetの入力が不正です。")
        }
        let variables = Dictionary(uniqueKeysWithValues: zip(Array("xyza"), values))
        let equations = expression.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...4).contains(equations.count) else { throw RunnerError(localized: "nuggetOffsetは4成分までです。") }
        return try equations.map { equation in
            var parser = Arithmetic(characters: Array(equation.filter { !$0.isWhitespace }), variables: variables)
            let result = try parser.sum(depth: 0)
            guard parser.index == parser.characters.count, result.isFinite else { throw RunnerError(localized: "未対応のnuggetOffset式です。") }
            return String(result)
        }.joined(separator: " ")
    }

    private struct Arithmetic {
        let characters: [Character]
        let variables: [Character: Double]
        var index = 0
        mutating func sum(depth: Int) throws -> Double {
            var value = try product(depth: depth + 1)
            while index < characters.count, characters[index] == "+" || characters[index] == "-" {
                let op = characters[index]; index += 1
                let right = try product(depth: depth + 1)
                value = op == "+" ? value + right : value - right
            }
            return value
        }
        mutating func product(depth: Int) throws -> Double {
            var value = try atom(depth: depth + 1)
            while index < characters.count, ["*", "/", "%"].contains(characters[index]) {
                let op = characters[index]; index += 1
                let right = try atom(depth: depth + 1)
                value = op == "*" ? value * right : (op == "/" ? value / right : value.truncatingRemainder(dividingBy: right))
            }
            return value
        }
        mutating func atom(depth: Int) throws -> Double {
            guard depth < 32, index < characters.count else { throw RunnerError(localized: "nuggetOffset式が不正または深すぎます。") }
            let c = characters[index]; index += 1
            if c == "+" { return try atom(depth: depth + 1) }
            if c == "-" { return try -atom(depth: depth + 1) }
            if c == "(" {
                let value = try sum(depth: depth + 1)
                guard index < characters.count, characters[index] == ")" else { throw RunnerError(localized: "式の括弧が一致しません。") }
                index += 1; return value
            }
            if let value = variables[c] { return value }
            let start = index - 1
            while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
            guard let value = Double(String(characters[start..<index])), value.isFinite else { throw RunnerError(localized: "式に未対応の文字があります。") }
            return value
        }
    }
}
