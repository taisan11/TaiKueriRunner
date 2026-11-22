import Foundation
import CoreFoundation

struct StagedDocumentPreview: Sendable {
    let url: URL
    let directory: URL
}

struct HexDocumentPreview: Sendable {
    let text: String
    let totalBytes: Int
    let shownBytes: Int
}

struct PropertyListDocumentPreview: Sendable {
    let text: String
    let format: String
    let root: PropertyListNode
}

struct PropertyListNode: Identifiable, Sendable {
    let id: String
    let key: String
    let type: String
    let value: String
    let children: [PropertyListNode]?
}

enum DocumentPreview {
    static let maximumMediaBytes = 32 * 1024 * 1024
    static let maximumPlistBytes = 1_048_576
    static let maximumHexBytes = 65_536

    static func hexDump(_ data: Data) -> String {
        let bytes = Array(data.prefix(maximumHexBytes))
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ").padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%08X  ", offset) + hex + "  " + ascii
        }.joined(separator: "\n")
    }

    static func propertyList(_ data: Data) throws -> PropertyListDocumentPreview {
        guard data.count <= maximumPlistBytes else { throw RunnerError(localized: "Plist表示は1 MiBまでです。") }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        // Bound expansion before serializing a binary property list as XML.
        var nodes = 0, stringBytes = 0
        func node(_ value: Any, key: String, id: String, depth: Int) throws -> PropertyListNode {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= 32, nodes <= 10_000, stringBytes <= 2 * maximumPlistBytes else { throw RunnerError(localized: "Plistの構造・表示量が安全上限を超えています。") }
            if let dictionary = value as? [String: Any] {
                let children = try dictionary.keys.sorted().enumerated().map { index, childKey in
                    stringBytes += childKey.utf8.count
                    return try node(dictionary[childKey]!, key: childKey, id: id + "/\(index)", depth: depth + 1)
                }
                return PropertyListNode(id: id, key: key, type: "Dictionary", value: L("\(String(describing: children.count))項目"), children: children)
            } else if let array = value as? [Any] {
                let children = try array.enumerated().map { index, child in
                    try node(child, key: "[\(index)]", id: id + "/\(index)", depth: depth + 1)
                }
                return PropertyListNode(id: id, key: key, type: "Array", value: L("\(String(describing: children.count))項目"), children: children)
            }
            let type: String, summary: String
            if let text = value as? String {
                stringBytes += text.utf8.count
                type = "String"; summary = String(text.prefix(4096)) + (text.count > 4096 ? L("…（XML表示で全文を確認）") : "")
            } else if let bytes = value as? Data {
                stringBytes += bytes.count
                type = "Data"; summary = "\(bytes.count) bytes · " + bytes.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ") + (bytes.count > 32 ? " …" : "")
            } else if let date = value as? Date {
                type = "Date"; summary = date.ISO8601Format()
            } else if let number = value as? NSNumber {
                let boolean = CFGetTypeID(number) == CFBooleanGetTypeID()
                type = boolean ? "Boolean" : CFNumberIsFloatType(number) ? "Real" : "Integer"
                summary = boolean ? (number.boolValue ? "true" : "false") : number.stringValue
            } else { throw RunnerError(localized: "非対応のPlist値です。") }
            guard stringBytes <= 2 * maximumPlistBytes else { throw RunnerError(localized: "Plistの表示量が安全上限を超えています。") }
            return PropertyListNode(id: id, key: key, type: type, value: summary, children: nil)
        }
        let root = try node(object, key: "Root", id: "root", depth: 0)
        let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        guard xml.count <= 4 * maximumPlistBytes, let text = String(data: xml, encoding: .utf8) else { throw RunnerError(localized: "PlistのXML表示量が安全上限を超えています。") }
        return PropertyListDocumentPreview(text: text, format: format == .binary ? L("バイナリPlist") : "XML Plist", root: root)
    }
}
