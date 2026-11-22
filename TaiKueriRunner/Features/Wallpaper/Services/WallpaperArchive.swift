import Foundation

struct WallpaperDescriptor: Identifiable, Equatable, Sendable {
    let prefix: String
    let provider: String
    let title: String
    let fileCount: Int
    let bytes: Int
    var previewEntry: String? = nil
    var id: String { prefix }
}

struct WallpaperArchive: Sendable {
    let url: URL
    let snapshot: FileBackupStore.Snapshot
    let descriptors: [WallpaperDescriptor]
    var template: BatterTemplate? = nil
}

enum WallpaperPaths {
    static let store = "Library/Application Support/PRBPosterExtensionDataStore/61"
    static let providers: Set<String> = [
        "com.apple.WallpaperKit.CollectionsPoster", "com.apple.MercuryPoster",
        "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    ]

    // Foundation directory URLs can use /private/var even when the caller used
    // /var. Normalize this known alias lexically; do not resolve arbitrary links.
    static func normalized(_ path: String) throws -> String {
        let canonical = try FileRules.canonical(path)
        if canonical == "/private/var" { return "/var" }
        return canonical.hasPrefix("/private/var/") ? String(canonical.dropFirst(8)) : canonical
    }

    static func directoryAncestors(_ path: String, container: String) throws -> [String] {
        let root = try normalized(container), target = try normalized(path)
        guard root != "/", target == root || target.hasPrefix(root + "/") else {
            throw RunnerError(localized: "PosterBoardコンテナの外は壁紙の読み取り対象にできません。")
        }
        var result = [root], current = root
        for component in target.dropFirst(root.count).split(separator: "/") {
            current += "/" + component
            result.append(current)
        }
        return result
    }

    static func listedEntry(_ entry: FileEntry, in parent: String) throws -> FileEntry {
        // Rebuild the immediate child from its enumerated name. Never splice
        // a URL-returned absolute path into a differently spelled parent path.
        let path = try normalized(FileRules.child(entry.name, in: normalized(parent)).path)
        return FileEntry(path: path, name: entry.name, isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink,
                         size: entry.size, modified: entry.modified)
    }

    static func container(_ path: String) throws -> String {
        let canonical = try normalized(path)
        guard let result = LaunchServicesPaths.container(canonical, root: LaunchServicesPaths.applicationRoot) else {
            throw RunnerError(localized: "PosterBoardのApplication/UUIDデータコンテナを指定してください。")
        }
        return result
    }

    static func descriptors(container path: String, provider: String) throws -> String {
        guard providers.contains(provider) else { throw RunnerError(localized: "この壁紙プロバイダーには対応していません。") }
        return try container(path) + "/" + store + "/Extensions/" + provider + "/descriptors"
    }

    static func validateDestination(_ rawPath: String) throws {
        let path = try normalized(rawPath)
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { throw RunnerError(localized: "壁紙の追加先が不正です。") }
        let provider = String(parts[parts.count - 2])
        let suffix = "/" + store + "/Extensions/" + provider + "/descriptors"
        guard path.hasSuffix(suffix),
              try descriptors(container: String(path.dropLast(suffix.count)), provider: provider) == path else {
            throw RunnerError(localized: "壁紙はPosterBoardの61/Extensions内のdescriptorsにだけ追加できます。")
        }
    }

    static func installed(_ rawPath: String) throws -> (container: String, provider: String, location: InstalledWallpaper.Location) {
        let path = try normalized(rawPath)
        let marker = "/" + store + "/Extensions/"
        guard let range = path.range(of: marker) else { throw RunnerError(localized: "壁紙の場所が不正です。") }
        let root = try container(String(path[..<range.lowerBound]))
        let parts = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, WallpaperLibraryReader.validProvider(parts[0]),
              let location = InstalledWallpaper.Location(rawValue: parts[1]), UUID(uuidString: parts[2]) != nil,
              path == root + marker + parts.joined(separator: "/") else { throw RunnerError(localized: "壁紙の場所が不正です。") }
        return (root, parts[0], location)
    }
}

enum WallpaperImporter {
    static let maximumBytes = 256 * 1024 * 1024

    static func inspect(_ url: URL) throws -> WallpaperArchive {
        guard ["tendie", "tendies", "batter", "zip"].contains(url.pathExtension.lowercased()) else {
            throw RunnerError(localized: "tendie / tendies / batterファイルを選択してください。同じ形式の.zipも利用できます。")
        }
        let before = try FileBackupStore.Snapshot(path: url.path)
        let (descriptors, template) = try StableFileReader.withFile(path: url.path, maximumBytes: WallpaperZIP.maximumArchiveBytes) { handle, size in
            let zip = try WallpaperZIP(handle: handle, size: size)
            let template = try BatterTemplate.inspect(zip, required: url.pathExtension.lowercased() == "batter")
            return (try candidates(in: zip, template: template), template)
        }
        guard try FileBackupStore.Snapshot(path: url.path) == before else { throw RunnerError(localized: "ZIPが変更されました。選び直してください。") }
        guard !descriptors.isEmpty else {
            throw RunnerError(localized: "tendie形式の壁紙が見つかりません。PosterBoardのデータ書き出しや通常のZIPは読み込めません。")
        }
        return WallpaperArchive(url: url, snapshot: before, descriptors: descriptors, template: template)
    }

    private static func location(_ name: String) -> (prefix: String, provider: String)? {
        let parts = name.split(separator: "/").map(String.init)
        // Nugget package folders: descriptor/, ordered-descriptors/, video-descriptor/, mercury-descriptor/.
        guard let index = parts.firstIndex(where: { name in
            let tokens = name.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            return tokens.filter { $0 == "descriptor" || $0 == "descriptors" }.count == 1 &&
                tokens.allSatisfy { ["descriptor", "descriptors", "ordered", "video", "photos", "mercury"].contains($0) }
        }),
              parts.count > index + 2,
              !parts.prefix(index).contains(where: { ["prbposterextensiondatastore", "container", "data", "library", "configurations", "extensions"].contains($0.lowercased()) }) else { return nil }
        let folder = parts[index].lowercased()
        let provider = folder.contains("video") || folder.contains("photos") ? "com.apple.PhotosUIPrivate.PhotosPosterProvider" :
            (folder.contains("mercury") ? "com.apple.MercuryPoster" : "com.apple.WallpaperKit.CollectionsPoster")
        return (parts.prefix(index + 2).joined(separator: "/") + "/", provider)
    }

    private static func included(_ relative: String) -> Bool {
        if ["providerInfo.plist", "com.apple.posterkit.provider.descriptor.identifier", "com.apple.posterkit.role.identifier"].contains(relative) { return true }
        let parts = relative.split(separator: "/")
        return parts.count >= 4 && parts[0] == "versions" && Int(parts[1]).map { $0 >= 0 } == true && parts[2] == "contents"
    }

    private static func batterLocation(_ name: String, template: BatterTemplate) -> (prefix: String, provider: String)? {
        guard name.hasPrefix(template.root) else { return nil }
        let relative = String(name.dropFirst(template.root.count))
        if let direct = location(relative) { return (template.root + direct.prefix, direct.provider) }
        // Container templates are converted to *new* descriptors. Never restore
        // preferences, databases, configurations or overwrite the original UUID.
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first, first.lowercased() == "container" else { return nil }
        let base = first + "/" + WallpaperPaths.store + "/Extensions/"
        guard relative.hasPrefix(base) else { return nil }
        let tail = String(relative.dropFirst(base.count)).split(separator: "/").map(String.init)
        guard tail.count >= 4, WallpaperPaths.providers.contains(tail[0]), tail[1] == "descriptors" else { return nil }
        return (template.root + base + tail.prefix(3).joined(separator: "/") + "/", tail[0])
    }

    static func candidates(in zip: WallpaperZIP, template: BatterTemplate? = nil) throws -> [WallpaperDescriptor] {
        var grouped: [String: (String, [WallpaperZIP.Entry])] = [:]
        for entry in zip.entries where !entry.directory && !entry.name.split(separator: "/").contains("__MACOSX") {
            let entryLocation = template != nil ? batterLocation(entry.name, template: template!) : location(entry.name)
            if let location = entryLocation,
               included(String(entry.name.dropFirst(location.prefix.count))) {
                grouped[location.prefix, default: (location.provider, [])].1.append(entry)
            }
        }
        guard grouped.count <= 200 else { throw RunnerError(localized: "壁紙の候補は200件までです。") }
        return try grouped.sorted { $0.key < $1.key }.compactMap { prefix, group in
            let (provider, entries) = group
            guard entries.contains(where: { $0.name == prefix + "providerInfo.plist" }),
                  let identifier = entries.first(where: { $0.name == prefix + "com.apple.posterkit.provider.descriptor.identifier" }),
                  entries.contains(where: { $0.name.hasPrefix(prefix + "versions/") }) else { return nil }
            let bytes = entries.reduce(0) { $0 + $1.size }
            guard entries.count < 9_000, bytes <= maximumBytes,
                  entries.allSatisfy({ $0.size <= WallpaperZIP.maximumFileBytes && $0.compressed <= WallpaperZIP.maximumFileBytes }),
                  identifier.size <= 4096 else { throw RunnerError(localized: "壁紙が上限（256 MiB・9,000ファイル・単一64 MiB）を超えています。") }
            let id = String(data: try zip.contents(identifier), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, id.rangeOfCharacter(from: .controlCharacters) == nil else { throw RunnerError(localized: "壁紙の識別子が不正です。") }
            let asset = entries.compactMap { $0.name.split(separator: "/").first { $0.hasSuffix(".wallpaper") } }.first
            let folder = prefix.split(separator: "/").last.map(String.init) ?? id
            let preview = WallpaperDisplay.preview(in: entries.map(\.name))
            return WallpaperDescriptor(prefix: prefix, provider: provider,
                                       title: WallpaperDisplay.title(asset: asset.map(String.init), identifier: id, fallback: folder),
                                       fileCount: entries.count, bytes: bytes, previewEntry: preview)
        }
    }

    static func preview(_ descriptor: WallpaperDescriptor, archive: WallpaperArchive) throws -> Data? {
        guard archive.descriptors.contains(descriptor), let name = descriptor.previewEntry,
              try FileBackupStore.Snapshot(path: archive.url.path) == archive.snapshot else { return nil }
        return try StableFileReader.withFile(path: archive.url.path, maximumBytes: WallpaperZIP.maximumArchiveBytes) { handle, size in
            let zip = try WallpaperZIP(handle: handle, size: size)
            guard let entry = zip.entries.first(where: { $0.name == name }), entry.size <= WallpaperThumbnail.maximumBytes else { return nil }
            return try WallpaperThumbnail.make(zip.contents(entry))
        }
    }

    static func batterPreview(_ name: String, archive: WallpaperArchive) throws -> Data? {
        guard let template = archive.template, (template.previews ?? []).contains(name),
              try FileBackupStore.Snapshot(path: archive.url.path) == archive.snapshot else { return nil }
        try BatterTemplate.validatePath(name)
        let allowed = try (template.resources ?? []).contains { pattern in
            try BatterRenderer.validatePattern(pattern)
            return BatterRenderer.matches(pattern, path: name, descendants: false)
        }
        guard allowed else { return nil }
        return try StableFileReader.withFile(path: archive.url.path, maximumBytes: WallpaperZIP.maximumArchiveBytes) { handle, size in
            let zip = try WallpaperZIP(handle: handle, size: size)
            guard let entry = zip.entries.first(where: { $0.name == template.root + name }),
                  entry.size <= WallpaperThumbnail.maximumBytes else { return nil }
            return try WallpaperThumbnail.make(zip.contents(entry))
        }
    }

    // The caller supplies a fresh private directory; only one selected descriptor is materialized.
    static func stage(_ descriptor: WallpaperDescriptor, from archive: WallpaperArchive, in directory: URL,
                      selections: BatterSelections = BatterSelections()) throws -> URL {
        guard archive.descriptors.contains(descriptor), try FileBackupStore.Snapshot(path: archive.url.path) == archive.snapshot else {
            throw RunnerError(localized: "選択後にZIPが変更されました。選び直してください。")
        }
        let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try StableFileReader.withFile(path: archive.url.path, maximumBytes: WallpaperZIP.maximumArchiveBytes) { handle, size in
                let zip = try WallpaperZIP(handle: handle, size: size)
                let template = try BatterTemplate.inspect(zip, required: archive.template != nil)
                guard template == archive.template, try candidates(in: zip, template: template).contains(descriptor) else {
                    throw RunnerError(localized: "壁紙の目録・テンプレートが変更されました。")
                }
                let payload: [(String, Data)]
                if let template {
                    payload = try BatterRenderer.render(zip, template: template, selections: selections)
                        .filter { $0.key.hasPrefix(descriptor.prefix) && included(String($0.key.dropFirst(descriptor.prefix.count))) }
                        .map { (String($0.key.dropFirst(descriptor.prefix.count)), $0.value) }
                } else {
                    payload = try zip.entries.filter { !$0.directory && $0.name.hasPrefix(descriptor.prefix) &&
                        included(String($0.name.dropFirst(descriptor.prefix.count))) }.map {
                        (String($0.name.dropFirst(descriptor.prefix.count)), try zip.contents($0))
                    }
                }
                guard payload.contains(where: { $0.0 == "providerInfo.plist" }),
                      let identifier = payload.first(where: { $0.0 == "com.apple.posterkit.provider.descriptor.identifier" })?.1,
                      identifier.count <= 4096, let identifierText = String(data: identifier, encoding: .utf8),
                      !identifierText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      identifierText.trimmingCharacters(in: .whitespacesAndNewlines).rangeOfCharacter(from: .controlCharacters) == nil,
                      payload.contains(where: { $0.0.hasPrefix("versions/") }),
                      payload.count < 9000, payload.reduce(0, { $0 + $1.1.count }) <= maximumBytes else {
                    throw RunnerError(localized: "選択した壁紙は設定によって削除されたか、必要なファイルが不足しています。設定または壁紙の選択を変更してください。")
                }
                let newID = Int.random(in: 100_000_000...999_999_999)
                // Semantic identifiers (Mercury/Photos) must not be converted into numbers.
                let numericID = descriptor.provider == "com.apple.WallpaperKit.CollectionsPoster" &&
                    Int(String(data: identifier, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") != nil
                for (relative, content) in payload {
                    try Task.checkCancellation()
                    var bytes = content
                    let name = (relative as NSString).lastPathComponent
                    if name.hasSuffix(".plist") || name == "com.apple.posterkit.provider.contents.userInfo" ||
                        name == "com.apple.posterkit.provider.contents.galleryOptions" {
                        guard bytes.count <= 1_048_576 else { throw RunnerError(localized: "壁紙メタデータは1 MiBまでです。") }
                        // Parse as plist only; never instantiate archived Objective-C classes.
                        _ = try PropertyListSerialization.propertyList(from: bytes, format: nil)
                    }
                    if numericID { bytes = try remap(bytes, relative: relative, identifier: newID) }
                    let destination = target.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: destination, options: .withoutOverwriting)
                }
            }
            guard try FileBackupStore.Snapshot(path: archive.url.path) == archive.snapshot else { throw RunnerError(localized: "ZIPが変更されました。") }
            _ = try FileBackupStore(root: directory.appendingPathComponent("unused")).snapshot(target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private static func remap(_ bytes: Data, relative: String, identifier: Int) throws -> Data {
        if relative == "com.apple.posterkit.provider.descriptor.identifier" { return Data(String(identifier).utf8) }
        let name = (relative as NSString).lastPathComponent
        guard name == "Wallpaper.plist" || name == "com.apple.posterkit.provider.contents.userInfo" else { return bytes }
        guard bytes.count <= 1_048_576 else { throw RunnerError(localized: "壁紙のメタデータが大きすぎます。") }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let value = try PropertyListSerialization.propertyList(from: bytes, format: &format)
        func update(_ value: Any, depth: Int) throws -> Any {
            guard depth <= 32 else { throw RunnerError(localized: "壁紙メタデータの階層が深すぎます。") }
            if var dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "wallpaperRepresentingIdentifier" || (name == "Wallpaper.plist" && depth == 0 && key == "identifier") {
                        dictionary[key] = identifier
                    } else { dictionary[key] = try update(child, depth: depth + 1) }
                }
                return dictionary
            }
            if let array = value as? [Any] { return try array.map { try update($0, depth: depth + 1) } }
            return value
        }
        return try PropertyListSerialization.data(fromPropertyList: update(value, depth: 0), format: format, options: 0)
    }

    static func refreshSettings(_ original: Data) throws -> Data {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var settings = try PropertyListSerialization.propertyList(from: original, format: &format) as? [String: Any] else {
            throw RunnerError(localized: "PosterBoardの設定がDictionaryではありません。")
        }
        settings["PBF_RESET_FILE_PROTECTIONS"] = true
        settings["PBF_LOCALE_DID_CHANGE"] = false
        return try PropertyListSerialization.data(fromPropertyList: settings, format: format, options: 0)
    }
}
