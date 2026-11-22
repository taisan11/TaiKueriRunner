import Foundation
import Observation

@MainActor
@Observable
final class MobileGestaltModel {
    private(set) var document: MobileGestaltDocument?
    private(set) var loading = false
    var errorMessage: String?
    private var loadID = UUID()

    func refresh(using loader: () async throws -> MobileGestaltDocument) async {
        guard !Task.isCancelled, !loading, document?.changes.isEmpty != false else { return }
        await load(using: loader)
    }

    func load(using loader: () async throws -> MobileGestaltDocument) async {
        let id = UUID()
        loadID = id; loading = true; errorMessage = nil
        defer { if loadID == id { loading = false } }
        do {
            let result = try await loader()
            try Task.checkCancellation()
            guard loadID == id else { return }
            document = result
        } catch is CancellationError {} catch {
            if loadID == id && !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func edit(_ value: PropertyListValue, entry: MobileGestaltEntry) throws {
        guard document != nil, !loading else { throw RunnerError(localized: "ファイルを読み込んでください。") }
        try document?.set(value, at: entry.path)
    }

    func discardChanges() { document?.discardChanges() }

    func stage(_ feature: MobileGestaltFeature, choice: String) throws {
        guard var draft = document, !loading else { throw RunnerError(localized: "ファイルを読み込んでください。") }
        try feature.stage(choice: choice, in: &draft)
        document = draft
    }

    func stage(_ feature: MobileGestaltFeature, input: String) throws {
        guard var draft = document, !loading else { throw RunnerError(localized: "ファイルを読み込んでください。") }
        try feature.stage(input: input, in: &draft)
        document = draft
    }

    func reset(_ feature: MobileGestaltFeature) throws {
        guard var draft = document, !loading else { throw RunnerError(localized: "ファイルを読み込んでください。") }
        try feature.reset(in: &draft)
        document = draft
    }

    func acceptSaved(_ data: Data) {
        guard let path = document?.path else { return }
        do { document = try MobileGestaltDocument(path: path, data: data); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

enum PlistScalarEditor {
    static func input(for value: PropertyListValue) -> String {
        switch value {
        case .string(let value), .integer(let value): value
        case .real(let value): String(value)
        case .date(let value): value.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        default: value.summary
        }
    }

    static func parse(_ input: String, like value: PropertyListValue) throws -> PropertyListValue {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case .string: return .string(input)
        case .integer:
            if let signed = Int64(trimmed) { return .integer(String(signed)) }
            if let unsigned = UInt64(trimmed) { return .integer(String(unsigned)) }
            throw RunnerError(localized: "64ビット整数を入力してください。")
        case .real:
            guard let number = Double(trimmed), number.isFinite else { throw RunnerError(localized: "有限の数値を入力してください。") }
            return .real(number)
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: trimmed)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = date ?? formatter.date(from: trimmed) else { throw RunnerError(localized: "ISO 8601形式の日付を入力してください。") }
            return .date(date)
        default: throw RunnerError(localized: "この型は直接編集できません。")
        }
    }
}
