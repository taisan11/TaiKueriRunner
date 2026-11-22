import Foundation
import CoreFoundation

// Typed, Sendable values keep plist types intact without passing Any across actors.
indirect enum PropertyListValue: Equatable, Sendable {
    case dictionary([String: PropertyListValue]), array([PropertyListValue])
    case string(String), boolean(Bool), integer(String), real(Double), date(Date), data(Data)

    var typeName: String {
        switch self {
        case .dictionary: "Dictionary"
        case .array: "Array"
        case .string: "String"
        case .boolean: "Boolean"
        case .integer: "Integer"
        case .real: "Real"
        case .date: "Date"
        case .data: "Data"
        }
    }

    var summary: String {
        switch self {
        case .dictionary(let values): L("\(String(describing: values.count))項目")
        case .array(let values): L("\(String(describing: values.count))項目")
        case .string(let value): String(value.prefix(1024))
        case .boolean(let value): value ? "true" : "false"
        case .integer(let value): value
        case .real(let value): String(value)
        case .date(let value): value.ISO8601Format()
        case .data(let value): "\(value.count) bytes · " + value.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    var isContainer: Bool {
        switch self { case .dictionary, .array: true; default: false }
    }

    static func decode(_ data: Data) throws -> (value: PropertyListValue, format: PropertyListSerialization.PropertyListFormat) {
        guard data.count <= DocumentPreview.maximumPlistBytes else { throw RunnerError(localized: "Plistの読み書きは1 MiBまでです。") }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard format == .binary || format == .xml else { throw RunnerError(localized: "バイナリまたはXML Plistを指定してください。") }
        var nodes = 0, bytes = 0
        func convert(_ object: Any, depth: Int) throws -> PropertyListValue {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= 32, nodes <= 10_000 else { throw RunnerError(localized: "Plistの構造が上限を超えています。") }
            if let dictionary = object as? [String: Any] {
                var values: [String: PropertyListValue] = [:]
                for (key, child) in dictionary {
                    bytes += key.utf8.count
                    guard bytes <= 2 * DocumentPreview.maximumPlistBytes else { throw RunnerError(localized: "Plistの展開量が上限を超えています。") }
                    values[key] = try convert(child, depth: depth + 1)
                }
                return .dictionary(values)
            }
            if let array = object as? [Any] { return .array(try array.map { try convert($0, depth: depth + 1) }) }
            if let string = object as? String {
                bytes += string.utf8.count
                guard bytes <= 2 * DocumentPreview.maximumPlistBytes else { throw RunnerError(localized: "Plistの展開量が上限を超えています。") }
                return .string(string)
            }
            if let data = object as? Data {
                bytes += data.count
                guard bytes <= 2 * DocumentPreview.maximumPlistBytes else { throw RunnerError(localized: "Plistの展開量が上限を超えています。") }
                return .data(data)
            }
            if let date = object as? Date { return .date(date) }
            if let number = object as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
                if CFNumberIsFloatType(number) {
                    guard number.doubleValue.isFinite else { throw RunnerError(localized: "非有限の数値は編集できません。") }
                    return .real(number.doubleValue)
                }
                return .integer(number.stringValue)
            }
            throw RunnerError(localized: "非対応のPlist値です。")
        }
        return (try convert(object, depth: 0), format)
    }

    func encode(format: PropertyListSerialization.PropertyListFormat) throws -> Data {
        func object(_ value: PropertyListValue) throws -> Any {
            switch value {
            case .dictionary(let values): return try values.mapValues(object)
            case .array(let values): return try values.map(object)
            case .string(let value): return value
            case .boolean(let value): return NSNumber(value: value)
            case .integer(let value):
                if let signed = Int64(value) { return NSNumber(value: signed) }
                if let unsigned = UInt64(value) { return NSNumber(value: unsigned) }
                throw RunnerError(localized: "整数の範囲を超えています。")
            case .real(let value):
                guard value.isFinite else { throw RunnerError(localized: "有限の数値を指定してください。") }
                return NSNumber(value: value)
            case .date(let value): return value
            case .data(let value): return value
            }
        }
        let bytes = try PropertyListSerialization.data(fromPropertyList: object(self), format: format, options: 0)
        _ = try Self.decode(bytes)
        return bytes
    }
}
