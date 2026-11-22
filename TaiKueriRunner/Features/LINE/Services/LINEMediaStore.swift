import Foundation

// Identifies one message's image across chats. The message MID alone is
// generally unique, but the device thumbnail path also contains the chat MID.
struct LINEMediaKey: Hashable, Sendable {
    let chatMID: String
    let messageID: String
}

struct LINEAttachmentFile: Sendable, Equatable {
    let path: String
    let fileName: String
}

// What the gallery can show for an image message. The badge only appears for
// `.thumbnailOnly`, i.e. after the attachment folder was listed successfully and
// held no file for this message: a permission denial stays `.unknown` so a
// missing original is never inferred from an unreadable folder.
enum LINEMediaAvailability: Sendable, Equatable {
    case full
    case thumbnailOnly
    case unavailable
    case unknown
}

// Loads thumbnails and stickers from LINE's shared App Group container and
// full attachments from the jp.naver.line app container. Only the requested
// file is read; nothing is copied until the user opens or shares an item.
actor LINEMediaStore {
    static let maximumThumbnailBytes = 8 * 1024 * 1024
    static let maximumImageBytes = 32 * 1024 * 1024
    static let maximumStickerBytes = 4 * 1024 * 1024
    static let maximumAttachmentBytes = 1024 * 1024 * 1024

    private let access: FileAccessManager
    private let accountMID: String
    private let containerPath: String?
    private let attachmentContainerPath: String?
    private var chatAttachments: [String: [String: [LINEAttachmentFile]]] = [:]
    private let cache = NSCache<NSString, NSData>()
    private var availabilityCache: [LINEMediaKey: LINEMediaAvailability] = [:]

    init(access: FileAccessManager, accountMID: String,
         containerPath: String?, attachmentContainerPath: String?) {
        self.access = access
        self.accountMID = accountMID
        self.containerPath = containerPath
        self.attachmentContainerPath = attachmentContainerPath
        cache.countLimit = 150
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func hasAttachment(chatMID: String, messageID: String) async -> Bool {
        guard let message = safeComponent(messageID),
              let attachments = await attachments(forChat: chatMID) else { return false }
        return !(attachments[message] ?? []).isEmpty
    }

    // Resolves what the gallery can display for each image message. Batch
    // callers pass a whole page so one container access session covers every
    // device thumbnail check.
    func imageAvailability(keys: [LINEMediaKey]) async -> [LINEMediaKey: LINEMediaAvailability] {
        if availabilityCache.count > 20_000 { availabilityCache.removeAll() }
        var resolved: [LINEMediaKey: LINEMediaAvailability] = [:]
        var pending: [(key: LINEMediaKey, path: String, attachmentListUnknown: Bool, attachmentSourcePresent: Bool)] = []
        for key in keys {
            if let cached = availabilityCache[key] {
                resolved[key] = cached
                continue
            }
            guard let chat = safeComponent(key.chatMID), let message = safeComponent(key.messageID) else {
                availabilityCache[key] = .unavailable
                continue
            }
            // nil means the attachment folder could not be listed (no app
            // container or a denial); an empty dictionary means it was listed
            // and holds nothing for this chat.
            let attachments = await attachments(forChat: key.chatMID)
            if let attachments, !(attachments[message] ?? []).isEmpty {
                availabilityCache[key] = .full
                resolved[key] = .full
                continue
            }
            guard let containerPath else {
                availabilityCache[key] = .unavailable
                continue
            }
            let path = containerPath + "/" + LINEDataStaging.privateStoreRelative
                + "/P_\(accountMID)/Message Thumbnails/\(chat)/\(message).thumb"
            pending.append((key, path, attachments == nil, attachmentContainerPath != nil))
        }
        guard !pending.isEmpty else { return resolved }
        do {
            let result = try await access.lineMediaFilesExist(paths: pending.map(\.path))
            for item in pending {
                let state: LINEMediaAvailability
                if result.present.contains(item.path) {
                    // The original may still exist when the attachment folder
                    // could not be listed, so do not badge an unverified state.
                    state = item.attachmentListUnknown ? .unknown : .thumbnailOnly
                } else if result.unknown.contains(item.path) {
                    // Unreadable is not the same as missing, so keep it visible.
                    state = .unknown
                } else if item.attachmentListUnknown, item.attachmentSourcePresent {
                    // The attachment folder exists but could not be listed, so
                    // a missing thumbnail does not prove the media is gone.
                    state = .unknown
                } else {
                    state = .unavailable
                }
                availabilityCache[item.key] = state
                resolved[item.key] = state
            }
        } catch is CancellationError {
            return [:]
        } catch {
            // If the batch itself fails, do not hide every row on an uncertain
            // result. The next page or reload can check again.
            for item in pending { resolved[item.key] = .unknown }
        }
        return resolved
    }

    // Single-message lookup for the detail screen and chat bubbles.
    func availability(chatMID: String, messageID: String) async -> LINEMediaAvailability {
        let key = LINEMediaKey(chatMID: chatMID, messageID: messageID)
        return await imageAvailability(keys: [key])[key] ?? .unavailable
    }

    func hasImage(chatMID: String, messageID: String) async -> Bool {
        await availability(chatMID: chatMID, messageID: messageID) != .unavailable
    }

    func thumbnail(chatMID: String, messageID: String) async -> Data? {
        guard let chat = safeComponent(chatMID), let message = safeComponent(messageID),
              let containerPath else { return nil }
        let key = "t:\(message)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let path = containerPath + "/" + LINEDataStaging.privateStoreRelative
            + "/P_\(accountMID)/Message Thumbnails/\(chat)/\(message).thumb"
        guard let data = try? await access.readLINEMediaFile(path: path, maximumBytes: Self.maximumThumbnailBytes) else {
            return nil
        }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    func image(chatMID: String, messageID: String) async -> Data? {
        guard let chat = safeComponent(chatMID), let message = safeComponent(messageID) else { return nil }
        let key = "f:\(message)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        var data: Data?
        if let location = await attachmentLocation(chatMID: chatMID, messageID: message, kind: .image) {
            data = try? await access.readLINEMediaFile(path: location.path, maximumBytes: Self.maximumImageBytes)
        }
        // The shared container stores only thumbnails, not full-sized images.
        if data == nil {
            data = await thumbnail(chatMID: chat, messageID: message)
        }
        if let data { cache.setObject(data as NSData, forKey: key, cost: data.count) }
        return data
    }

    // Copies a video or file from the LINE app container into a private
    // temporary directory. Streaming to disk avoids holding a large file in
    // memory just to hand it to Quick Look.
    func attachmentFile(chatMID: String, messageID: String, kind: LINEMessageKind) async -> URL? {
        guard let location = await attachmentLocation(chatMID: chatMID, messageID: messageID, kind: kind) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LINEMediaShare-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let name = safeFileName(attachmentName(location: location, messageID: messageID),
                                    fallback: "LINE-attachment")
            let url = directory.appendingPathComponent(name)
            try await access.copyLINEMediaFile(path: location.path, to: url,
                                               maximumBytes: Self.maximumAttachmentBytes)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func attachmentName(chatMID: String, messageID: String, kind: LINEMessageKind) async -> String? {
        guard let location = await attachmentLocation(chatMID: chatMID, messageID: messageID, kind: kind) else {
            return nil
        }
        return attachmentName(location: location, messageID: messageID)
    }

    func sticker(packageID: String?, version: String?, stickerID: String?) async -> Data? {
        guard let package = packageID.flatMap(safeComponent),
              let sticker = stickerID.flatMap(safeComponent),
              let containerPath else { return nil }
        let version = version.flatMap(safeComponent) ?? "1"
        let key = "s:\(package):\(version):\(sticker)" as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let roots = [
            containerPath + "/" + LINEDataStaging.privateStoreRelative + "/P_\(accountMID)/Sticker Packages",
            containerPath + "/Library/Caches/PrivateStore/P_\(accountMID)/Stray Sticker Packages"
        ]
        for root in roots {
            let path = "\(root)/\(package).\(version).linestk/\(sticker)@2x.png"
            if let found = try? await access.readLINEMediaFile(path: path, maximumBytes: Self.maximumStickerBytes) {
                cache.setObject(found as NSData, forKey: key, cost: found.count)
                return found
            }
        }
        return nil
    }

    // MARK: - Direct app-container attachments

    private func attachments(forChat chatMID: String) async -> [String: [LINEAttachmentFile]]? {
        if let cached = chatAttachments[chatMID] { return cached }
        guard let attachmentContainerPath, let chat = safeComponent(chatMID) else { return nil }
        let directory = attachmentContainerPath + "/" + LINEDataStaging.privateStoreRelative
            + "/P_\(accountMID)/Message Attachments/\(chat)"
        let names: [String]
        do {
            names = try await access.listLINEMediaFiles(path: directory)
        } catch {
            // A chat without an attachment folder is confirmed empty; a
            // permission denial is not, and must keep the original unverified.
            guard LINEDataStaging.isMissingPath(error) else { return nil }
            names = []
        }
        var result: [String: [LINEAttachmentFile]] = [:]
        for name in names {
            let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? name
            let messageID = stem.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? stem
            guard !messageID.isEmpty, messageID.allSatisfy(\.isNumber) else { continue }
            result[messageID, default: []].append(
                LINEAttachmentFile(path: directory + "/" + name, fileName: name)
            )
        }
        if chatAttachments.count > 40 { chatAttachments.removeAll() }
        chatAttachments[chatMID] = result
        return result
    }

    private func attachmentLocation(chatMID: String, messageID: String,
                                    kind: LINEMessageKind) async -> LINEAttachmentFile? {
        guard let message = safeComponent(messageID),
              let locations = await attachments(forChat: chatMID)?[message],
              !locations.isEmpty else { return nil }
        let preferred: Set<String>
        switch kind {
        case .image, .extImage:
            preferred = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"]
        case .video:
            preferred = ["mp4", "mov", "m4v", "webm"]
        case .audio:
            preferred = ["mp3", "m4a", "aac", "wav", "caf"]
        case .pdf:
            preferred = ["pdf"]
        case .file:
            // Prefer a real document over an image preview when both exist.
            if let document = locations.first(where: {
                !["jpg", "jpeg", "png", "heic", "heif", "gif", "webp"].contains(ext($0.fileName))
            }) {
                return document
            }
            preferred = []
        default:
            preferred = []
        }
        if !preferred.isEmpty, let match = locations.first(where: { preferred.contains(ext($0.fileName)) }) {
            return match
        }
        return locations.first
    }

    private func attachmentName(location: LINEAttachmentFile, messageID: String) -> String {
        let prefix = messageID + "_"
        if location.fileName.hasPrefix(prefix) {
            return String(location.fileName.dropFirst(prefix.count))
        }
        return location.fileName
    }

    private func ext(_ fileName: String) -> String {
        fileName.lowercased().split(separator: ".").last.map(String.init) ?? ""
    }

    // MIDs and message IDs are ASCII identifiers. Reject path separators and
    // traversal before they can be interpolated into a container path.
    private func safeComponent(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 256, !value.contains("..") else { return nil }
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else {
            return nil
        }
        return value
    }

    private func safeFileName(_ raw: String, fallback: String) -> String {
        var name = URL(fileURLWithPath: raw).lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty || name == "." || name == ".." {
            name = fallback
        }
        return String(name.prefix(200))
    }
}
