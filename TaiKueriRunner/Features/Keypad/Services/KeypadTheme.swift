import Foundation
import ImageIO
import CoreGraphics

enum KeypadKey: String, CaseIterable, Sendable, Identifiable {
    case one = "1", two = "2", three = "3", four = "4", five = "5", six = "6"
    case seven = "7", eight = "8", nine = "9", star = "*", zero = "0", pound = "#"
    var id: String { rawValue }
}

struct KeypadAssetName: Equatable, Sendable {
    let key: KeypadKey
    let locale: String
    let style: String
    let bold: Bool
    let highlighted: Bool
    let leaf: String

    init?(_ leaf: String) {
        guard leaf.utf8.count <= 255, !leaf.contains("/"), !leaf.contains("\\"),
              leaf.rangeOfCharacter(from: .controlCharacters) == nil,
              let dash = leaf.firstIndex(of: "-") else { return nil }
        let locale = String(leaf[..<dash])
        guard locale.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,31}$"#, options: .regularExpression) != nil else { return nil }
        let remaining = leaf[leaf.index(after: dash)...]
        guard remaining.count >= 3, let first = remaining.first, let key = KeypadKey(rawValue: String(first)),
              remaining.dropFirst().first == "-" else { return nil }
        let endings: [(String, String, Bool, Bool)] = [
            ("-hi-white-bold.png", "white", true, true), ("-hi-mask-bold.png", "mask", true, true),
            ("-white-bold.png", "white", true, false), ("-mask-bold.png", "mask", true, false),
            ("-hi-white.png", "white", false, true), ("-hi-mask.png", "mask", false, true),
            ("-white.png", "white", false, false), ("-mask.png", "mask", false, false)
        ]
        guard let ending = endings.first(where: { leaf.hasSuffix($0.0) }) else { return nil }
        self.key = key; self.locale = locale; style = ending.1; bold = ending.2; highlighted = ending.3; self.leaf = leaf
    }
}

enum KeypadPaths {
    static func phoneDirectory(_ container: String) throws -> String {
        try WallpaperPaths.container(container) + "/Library/Caches/TelephonyUI-10"
    }
    static func root(for directory: String) throws -> String {
        let path = try WallpaperPaths.normalized(directory)
        let suffix = "/Library/Caches/TelephonyUI-10"
        guard path.hasSuffix(suffix),
              let container = try? WallpaperPaths.container(String(path.dropLast(suffix.count))),
              try phoneDirectory(container) == path else {
            throw RunnerError(localized: "電話アプリのキーパッド以外は読み書きできません。")
        }
        return container
    }
    static func validateFile(_ path: String) throws {
        let url = URL(fileURLWithPath: try WallpaperPaths.normalized(path))
        _ = try root(for: url.deletingLastPathComponent().path)
        guard KeypadAssetName(url.lastPathComponent) != nil else { throw RunnerError(localized: "キーパッド画像以外は変更できません。") }
    }
}

struct KeypadTheme: Sendable {
    struct Asset: Sendable {
        let name: KeypadAssetName?
        let key: KeypadKey
        let data: Data
        let path: String
        let version: Int
    }
    let title: String
    let assets: [Asset]
    var keys: Set<KeypadKey> { Set(assets.map(\.key)) }

    func image(for key: KeypadKey, matching target: KeypadAssetName? = nil) -> Data? {
        asset(for: key, matching: target)?.data
    }

    func asset(for key: KeypadKey, matching target: KeypadAssetName? = nil) -> Asset? {
        assets.filter { $0.key == key }.sorted { a, b in
            func score(_ asset: Asset) -> Int {
                guard let name = asset.name else { return 0 }
                guard let target else { return (name.style == "white" ? 20 : 0) + (name.bold ? 0 : 2) + (name.highlighted ? 0 : 1) }
                return (name.leaf == target.leaf ? 1000 : 0) + (name.style == target.style ? 100 : 0) +
                    (name.locale == target.locale ? 20 : 0) + (name.bold == target.bold ? 4 : 0) +
                    (name.highlighted == target.highlighted ? 2 : 0)
            }
            if score(a) != score(b) { return score(a) > score(b) }
            return a.version == b.version ? a.path < b.path : a.version > b.version
        }.first
    }

    static func inspect(_ url: URL) throws -> KeypadTheme {
        guard ["passthm", "zip"].contains(url.pathExtension.lowercased()) else { throw RunnerError(localized: ".passthmまたは同じ形式の.zipを選択してください。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try StableFileReader.withFile(path: url.path, maximumBytes: 128 * 1024 * 1024) { handle, size in
            let zip = try WallpaperZIP(handle: handle, size: size)
            guard zip.entries.count <= 2000 else { throw RunnerError(localized: "キーパッドテーマは2,000項目までです。") }
            var assets: [Asset] = [], bytes = 0, seen = Set<String>()
            for entry in zip.entries where !entry.directory && !entry.name.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) {
                try Task.checkCancellation()
                let leaf = (entry.name as NSString).lastPathComponent
                let ext = (leaf as NSString).pathExtension.lowercased()
                guard ["png", "jpg", "jpeg"].contains(ext) else { continue }
                let stem = (leaf as NSString).deletingPathExtension
                let name = KeypadAssetName(stem + ".png")
                guard let key = name?.key ?? KeypadKey(rawValue: stem) else { continue }
                let versions = entry.name.split(separator: "/").compactMap { component -> Int? in
                    guard component.hasPrefix("TelephonyUI-") else { return nil }
                    return Int(component.dropFirst("TelephonyUI-".count))
                }
                let version = versions.max() ?? 0
                guard entry.size <= KeypadImage.maximumBytes, entry.compressed <= KeypadImage.maximumBytes else { throw RunnerError(localized: "キー画像は16 MiBまでです。") }
                let data = try zip.contents(entry)
                bytes += data.count
                guard assets.count < 512, bytes <= 128 * 1024 * 1024 else { throw RunnerError(localized: "テーマ画像は512枚・合計128 MiBまでです。") }
                try KeypadImage.validate(data)
                let identity = "\(version)/" + (name?.leaf ?? key.rawValue).lowercased()
                guard seen.insert(identity).inserted else { throw RunnerError(localized: "同じキー画像の候補が重複しています: \(String(describing: leaf))") }
                assets.append(Asset(name: name, key: key, data: data, path: entry.name, version: version))
            }
            guard !assets.isEmpty else { throw RunnerError(localized: "テーマにキー画像がありません。数字・*・#のPNG/JPEGか、TelephonyUI形式の名前が必要です。") }
            return KeypadTheme(title: url.deletingPathExtension().lastPathComponent, assets: assets)
        }
    }
}

struct KeypadRenderOptions: Sendable {
    var circular = false
}

enum KeypadImage {
    static let maximumBytes = 16 * 1024 * 1024

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 100_000_000 else {
            throw RunnerError(localized: "キー画像を読み取れません（静止画像・16 MiB・1億画素まで）。")
        }
    }

    static func render(_ data: Data, width: Int, height: Int, circular: Bool) throws -> Data {
        try Task.checkCancellation()
        try validate(data)
        guard (1...2500).contains(width), (1...2500).contains(height),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2500
              ] as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RunnerError(localized: "キー画像の変換に失敗しました（最大2500×2500 px）。")
        }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        if circular {
            let diameter = min(canvas.width, canvas.height)
            let circle = CGRect(x: canvas.midX - diameter / 2, y: canvas.midY - diameter / 2, width: diameter, height: diameter)
            context.addEllipse(in: circle)
            context.clip()
        }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let rect = CGRect(x: (CGFloat(width) - CGFloat(image.width) * scale) / 2,
                          y: (CGFloat(height) - CGFloat(image.height) * scale) / 2,
                          width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        let output = NSMutableData()
        guard let rendered = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw RunnerError(localized: "PNGの作成に失敗しました。")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else { throw RunnerError(localized: "変換後のキー画像が上限を超えています。") }
        try Task.checkCancellation()
        return output as Data
    }

    static func pngDimensions(_ data: Data) throws -> (Int, Int) {
        guard data.count >= 24, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(data: data[12..<16], encoding: .ascii) == "IHDR" else { throw RunnerError(localized: "端末のキー画像がPNGではありません。") }
        func integer(_ index: Int) -> Int { data[index..<index + 4].reduce(0) { ($0 << 8) | Int($1) } }
        let width = integer(16), height = integer(20)
        guard (1...2500).contains(width), (1...2500).contains(height) else { throw RunnerError(localized: "端末のキー画像の寸法が対応範囲外です。") }
        return (width, height)
    }
}
