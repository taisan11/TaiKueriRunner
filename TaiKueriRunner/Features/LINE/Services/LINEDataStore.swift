import Darwin
import Foundation
import SQLite3

// Reads the SQLite databases that LINE (jp.naver.line) keeps in its shared
// App Group container (group.com.linecorp.line). Only the databases needed for
// chat browsing are copied to a private staging folder; the container itself is
// never modified and media blobs are never decrypted.
struct LINEArchiveSummary: Sendable, Equatable {
    // MID of the account the PrivateStore folder belongs to ("P_<mid>").
    let accountMID: String
    // Bytes copied to staging when only the talk databases are included.
    let talkBytes: Int64
    // Bytes copied additionally when OpenChat (LineSquare.sqlite) is included.
    let openChatBytes: Int64
    var hasOpenChat: Bool { openChatBytes > 0 }
    var stagingBytes: Int64 { talkBytes + openChatBytes }
}

enum LINEScope: String, CaseIterable, Identifiable, Sendable {
    case talk
    case openChat
    var id: String { rawValue }
    var title: String { self == .talk ? L("トーク") : L("オープンチャット") }
}

enum LINEDataStaging {
    static let maximumBytes: Int64 = 3 * 1024 * 1024 * 1024
    static let privateStoreRelative = "Library/Application Support/PrivateStore"

    // Database roles copied out of the container. Staging names are fixed so
    // source paths can never influence the staging layout.
    private static let stagedNames = [
        "Line.sqlite": "Line.sqlite",
        "Line.sqlite-wal": "Line.sqlite-wal",
        "UnifiedGroup.sqlite": "UnifiedGroup.sqlite",
        "UnifiedGroup.sqlite-wal": "UnifiedGroup.sqlite-wal",
        "MessageExt.sqlite": "MessageExt.sqlite",
        "MessageExt.sqlite-wal": "MessageExt.sqlite-wal",
        "LineSquare.sqlite": "LineSquare.sqlite",
        "LineSquare.sqlite-wal": "LineSquare.sqlite-wal"
    ]

    // MARK: Live App Group container mode

    // Filesystem access adapter. The manager supplies per-path permission
    // retries (the sandbox denies subdirectory listings and file reads even
    // when the container root is readable); the direct adapter is used by
    // tests. Every operation must throw on denial — swallowing errors here
    // previously made permission failures look like missing databases.
    struct LINEStagingAccess {
        let listDirectory: (String) throws -> [String]
        let regularFileSize: (String) throws -> Int
        let copyFile: (String, String, Int) throws -> Void
    }

    static func directAccess() -> LINEStagingAccess {
        LINEStagingAccess(
            listDirectory: { path in try FileManager.default.contentsOfDirectory(atPath: path) },
            regularFileSize: { path in
                var info = stat()
                guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard info.st_mode & S_IFMT == S_IFREG else { throw RunnerError(localized: "LINEのDBへのリンク・特殊ファイルは読み取れません。") }
                return Int(info.st_size)
            },
            copyFile: { source, destination, size in
                try copyFile(source: source, expectedSize: size, to: URL(fileURLWithPath: destination))
            }
        )
    }

    // Missing paths are skipped; any other failure (permission denial
    // included) propagates so the caller can retry the exact denied path.
    static func isMissingPath(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) ||
            (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
    }

    private static func sizeIfPresent(_ path: String, access: LINEStagingAccess) throws -> Int? {
        do { return try access.regularFileSize(path) }
        catch { guard isMissingPath(error) else { throw error }; return nil }
    }

    // Locates the first (sorted) PrivateStore account that actually holds the
    // chat database inside a live container.
    static func inspect(container: String, access: LINEStagingAccess) throws -> LINEArchiveSummary? {
        let store = container + "/" + privateStoreRelative
        let names: [String]
        do { names = try access.listDirectory(store) }
        catch { guard isMissingPath(error) else { throw error }; return nil }
        for account in names.filter({ $0.hasPrefix("P_") && $0.count > 2 }).sorted() {
            let mid = String(account.dropFirst(2))
            if let summary = try inspect(messages: store + "/" + account + "/Messages", accountMID: mid, access: access) {
                return summary
            }
        }
        return nil
    }

    static func inspect(messages: String, accountMID: String, access: LINEStagingAccess) throws -> LINEArchiveSummary? {
        guard let main = try sizeIfPresent(messages + "/Line.sqlite", access: access) else { return nil }
        var talk: Int64 = Int64(main), openChat: Int64 = 0
        var sawOpenChat = false
        for role in stagedNames.keys.sorted() where role != "Line.sqlite" {
            guard let size = try sizeIfPresent(messages + "/" + role, access: access) else { continue }
            if role.hasPrefix("LineSquare") {
                openChat += Int64(size)
                if role == "LineSquare.sqlite" { sawOpenChat = true }
            } else {
                talk += Int64(size)
            }
        }
        return LINEArchiveSummary(accountMID: accountMID, talkBytes: talk, openChatBytes: sawOpenChat ? openChat : 0)
    }

    static func extract(messages: String, summary: LINEArchiveSummary,
                        includeOpenChat: Bool, to directory: URL, access: LINEStagingAccess) throws {
        var total: Int64 = 0
        var planned: [(source: String, destination: URL, size: Int)] = []
        for (role, staged) in stagedNames.sorted(by: { $0.value < $1.value }) {
            guard includeOpenChat || !role.hasPrefix("LineSquare") else { continue }
            guard let size = try sizeIfPresent(messages + "/" + role, access: access) else { continue }
            total += Int64(size)
            planned.append((messages + "/" + role, directory.appendingPathComponent(staged), size))
        }
        guard let main = planned.first(where: { $0.destination.lastPathComponent == "Line.sqlite" }) else {
            throw RunnerError(localized: "この共有フォルダにLINEのメッセージDBがありません。")
        }
        guard total <= maximumBytes else { throw RunnerError(localized: "LINE表示用のコピー合計が上限（3 GiB）を超えています。") }
        // Copy the main database first and verify it holds SQLite data before
        // anything else lands in the staging folder.
        try Task.checkCancellation()
        try access.copyFile(main.source, main.destination.path, main.size)
        let header = try FileHandle(forReadingFrom: main.destination).read(upToCount: 16)
        guard header == Data("SQLite format 3\0".utf8) else {
            throw RunnerError(localized: "LINEのメッセージDBがSQLiteデータベースではありません（暗号化の可能性）。")
        }
        for item in planned where item.destination.path != main.destination.path {
            try Task.checkCancellation()
            try access.copyFile(item.source, item.destination.path, item.size)
        }
    }

    // Links and special files are rejected, matching the SQLite snapshot rules.
    // On APFS the snapshot is an O(1) copy-on-write clone, so opening the
    // viewer does not have to read gigabytes of databases. Filesystems without
    // clone support fall back to the verified streaming copy below; a source
    // that changes mid-snapshot is rejected by either path.
    static func copyFile(source: String, expectedSize: Int, to destination: URL) throws {
        if try cloneFileIfPossible(source: source, expectedSize: expectedSize, to: destination) { return }
        try StableFileReader.withFile(path: source, maximumBytes: ApplicationDataExport.maximumArchiveBytes) { input, size in
            guard size == expectedSize else {
                throw RunnerError(localized: "コピー中にLINEのDBのサイズが変わりました。LINEを終了してから開いてください。")
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RunnerError(localized: "LINE表示用の一時コピーを作成できません。")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied = 0
            while copied < size {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: min(1_048_576, size - copied)) ?? Data()
                guard !bytes.isEmpty else { throw RunnerError(localized: "LINEのDBのコピー中にファイルが変わりました。LINEを終了してから開いてください。") }
                try output.write(contentsOf: bytes)
                copied += bytes.count
            }
        }
    }

    // Returns false when cloning is unavailable (non-APFS volume, unsupported
    // source, size already changed) so the caller can use the streaming copy.
    // Internal for the host tests that assert the clone path is taken.
    static func cloneFileIfPossible(source: String, expectedSize: Int, to destination: URL) throws -> Bool {
        guard let before = FileStamp(source), before.size == Int64(expectedSize) else { return false }
        guard clonefile(source, destination.path, 0) == 0 else {
            // Never leave a partial destination behind; the streaming copy
            // recreates the file and reports the precise error.
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        // Verify the source after the clone: a size-only check misses in-place
        // writes, and inode/device catch a replacement between the two stats.
        guard let after = FileStamp(source), after == before else {
            try? FileManager.default.removeItem(at: destination)
            throw RunnerError(localized: "コピー中にLINEのDBが変わりました。LINEを終了してから開いてください。")
        }
        // clonefile preserves the source mode; staging is private to this app.
        _ = chmod(destination.path, 0o600)
        return true
    }

    private struct FileStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modified: Int64
        let modifiedNanoseconds: Int64
        let changed: Int64
        let changedNanoseconds: Int64

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }
}

enum LINEChatKind: Sendable, Equatable {
    case selfChat, oneToOne, group, room, unknown

    var title: String {
        switch self {
        case .selfChat: L("自分")
        case .oneToOne: L("トーク")
        case .group: L("グループ")
        case .room: L("複数トーク")
        case .unknown: L("不明")
        }
    }

    var symbol: String {
        switch self {
        case .selfChat: "person.crop.square"
        case .oneToOne: "person"
        case .group: "person.3"
        case .room: "person.2"
        case .unknown: "questionmark.circle"
        }
    }

    // ZCHAT.ZTYPE follows LINE's talk type: 0 = 1:1, 1 = multi-person
    // talk/room, 2 = group. Some databases use 4 for a room, and exports that
    // omit ZTYPE can still be classified by the chat MID prefix (`c…` group,
    // `r…` room). 100 is the account's own "self" chat.
    init(type: Int64, mid: String, accountMID: String) {
        if mid == accountMID || type == 100 {
            self = .selfChat
        } else if type == 0 {
            self = .oneToOne
        } else if type == 2 {
            self = .group
        } else if type == 1 || type == 4 {
            self = .room
        } else if mid.hasPrefix("c") {
            self = .group
        } else if mid.hasPrefix("r") {
            self = .room
        } else {
            self = .unknown
        }
    }
}

struct LINEChatSummary: Identifiable, Sendable, Equatable {
    let id: Int64
    let mid: String
    let kind: LINEChatKind
    let name: String
    let memberNames: [String]
    let unread: Int
    let messageCount: Int
    let lastMessage: String?
    let lastUpdated: Date?
}

// MessageReactionType from LINE's Thrift schema (linejs resources/line/line.thrift).
// ZCUSTOMREACTION holds custom emoji; when it is empty the numeric
// ZREACTIONTYPE identifies one of LINE's predefined reactions.
enum LINEReactionType: Sendable {
    static func emoji(for raw: Int64) -> String? {
        switch raw {
        case 2: "👍"  // NICE
        case 3: "❤️"  // LOVE
        case 4: "😂"  // FUN
        case 5: "😮"  // AMAZING
        case 6: "😢"  // SAD
        case 7: "😱"  // OMG
        default: nil  // ALL / UNDO / unknown are not visible reactions.
        }
    }
}

enum LINEMessageKind: Sendable, Equatable {
    // Values 0...22 mirror LINE's Thrift ContentType enum. The iOS app also
    // writes a few larger local values, kept separate below.
    case text, image, video, audio, html, pdf, call, sticker, presence, gift
    case groupboard, applink, link, contact, file, location, postNotification
    case rich, chatEvent, music, payment, extImage, flex
    // iOS-only values observed in exports (not part of the Thrift enum).
    case banner, album, preview, aggregate
    case other(Int)

    var title: String {
        switch self {
        case .text: L("テキスト")
        case .image: L("画像")
        case .video: L("動画")
        case .audio: L("音声")
        case .html: "HTML"
        case .pdf: "PDF"
        case .call: L("通話")
        case .sticker: L("スタンプ")
        case .presence: L("プレゼンス")
        case .gift: L("ギフト")
        case .groupboard: L("グループボード")
        case .applink: L("アプリリンク")
        case .link: L("リンク")
        case .contact: L("連絡先")
        case .file: L("ファイル")
        case .location: L("位置情報")
        case .postNotification: L("通知")
        case .rich: L("リッチメッセージ")
        case .chatEvent: L("システム通知")
        case .music: L("音楽")
        case .payment: L("支払い")
        case .extImage: L("画像（拡張）")
        case .flex: "Flex"
        case .banner: L("バナー（Flex）")
        case .album: L("アルバム")
        case .preview: L("URLプレビュー")
        case .aggregate: L("まとめ")
        case .other(let raw): L("種類 \(String(describing: raw))")
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.bubble"
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .pdf: "doc.richtext"
        case .call: "phone"
        case .sticker: "seal"
        case .presence: "circle.dashed"
        case .gift: "gift"
        case .groupboard: "rectangle.3.group"
        case .applink: "app.badge"
        case .link: "link"
        case .contact: "person.crop.rounded.badge.clock"
        case .file: "doc"
        case .location: "mappin.and.ellipse"
        case .postNotification: "bell"
        case .rich: "text.bubble"
        case .chatEvent: "info.circle"
        case .music: "music.note"
        case .payment: "creditcard"
        case .extImage: "photo.on.rectangle"
        case .flex: "rectangle.on.rectangle"
        case .banner: "rectangle.on.rectangle"
        case .album: "rectangle.stack"
        case .preview: "safari"
        case .aggregate: "rectangle.grid.1x2"
        case .other: "tag"
        }
    }

    // LINE draws these as centered notices rather than chat bubbles.
    var isSystemNotice: Bool {
        switch self {
        case .call, .presence, .chatEvent: true
        default: false
        }
    }

    // Photo messages whose media is expected in Message Thumbnails or
    // Message Attachments. Videos have their own thumbnail but are not hidden
    // by the image-cache display option.
    var isImage: Bool {
        self == .image || self == .extImage
    }

    // ZCONTENTTYPE values observed in current iOS exports. The first group is
    // shared with LINE's Thrift ContentType enum, but iOS uses local values for
    // Flex (5), location (100), official-account images (96), multi-message
    // aggregates (111) and their child media (112), so those are mapped from
    // real data rather than from the protocol enum alone.
    init(contentType: Int64) {
        switch contentType {
        case 0: self = .text
        case 1: self = .image
        case 2: self = .video
        case 3: self = .audio
        case 4: self = .html
        case 5: self = .flex
        case 6: self = .call
        case 7: self = .sticker
        case 8: self = .presence
        case 9: self = .gift
        case 10: self = .groupboard
        case 11: self = .applink
        case 12: self = .link
        case 13: self = .contact
        case 14: self = .file
        case 15: self = .location
        case 16: self = .album
        case 17: self = .rich
        case 18: self = .chatEvent
        case 19: self = .music
        case 20: self = .payment
        case 21: self = .extImage
        case 22: self = .flex
        case 96: self = .image
        case 100: self = .location
        case 107: self = .preview
        case 111: self = .aggregate
        case 112: self = .image
        default: self = .other(Int(contentType))
        }
    }
}

struct LINEMessageReaction: Identifiable, Sendable, Equatable {
    let emoji: String
    let count: Int
    let isMine: Bool
    let reactorNames: [String]
    var id: String { emoji }
}

struct LINEReplyPreview: Sendable, Equatable {
    let messageID: String
    let senderName: String?
    let body: String
}

struct LINEMessage: Identifiable, Sendable, Equatable {
    let id: Int64
    let date: Date
    let messageMID: String?
    let senderName: String?
    let isMine: Bool
    let isSystem: Bool
    let kind: LINEMessageKind
    let text: String?
    let metadata: [String: String]
    let reactions: [LINEMessageReaction]
    let replyToID: String?
    let replyTo: LINEReplyPreview?
    // ZMESSAGE.ZREADCOUNT in current LINE databases. The count covers the
    // whole chat; the names of the readers are not stored locally.
    let readCount: Int

    var metadataLines: [String] { LINEMetadata.lines(kind: kind, metadata: metadata) }
    var body: String { LINEMetadata.body(kind: kind, text: text, metadata: metadata) }
    var fileName: String? {
        let value = metadata["FILE_NAME"] ?? metadata["fileName"]
        guard let value, !value.isEmpty else { return nil }
        return value
    }
    var fileSize: Int64? {
        (metadata["FILE_SIZE"] ?? metadata["fileSize"]).flatMap(Int64.init)
    }

    func withReplyTo(_ preview: LINEReplyPreview?) -> LINEMessage {
        LINEMessage(id: id, date: date, messageMID: messageMID, senderName: senderName,
                    isMine: isMine, isSystem: isSystem, kind: kind, text: text,
                    metadata: metadata, reactions: reactions, replyToID: replyToID,
                    replyTo: preview, readCount: readCount)
    }
}

struct LINEMessagePage: Sendable {
    // Oldest first, ready for display.
    let messages: [LINEMessage]
    let hasOlder: Bool
}

// A message that points at media in the shared container. The gallery resolves
// chat names from the already-loaded chat list and reads the media on demand.
struct LINEMediaMessage: Identifiable, Sendable, Equatable {
    let id: Int64
    let chatID: Int64
    let chatMID: String
    let message: LINEMessage
}

struct LINEMediaMessagePage: Sendable {
    let items: [LINEMediaMessage]
    let hasMore: Bool
}

enum LINEMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case images
    case files
    case stickers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("すべて")
        case .images: L("画像・動画")
        case .files: L("ファイル")
        case .stickers: L("スタンプ")
        }
    }

    // ZCONTENTTYPE values that can have a thumbnail, attachment or sticker.
    // Album rows themselves are skipped because their child images (112) are
    // listed separately.
    var contentTypes: [Int64] {
        switch self {
        case .all: [1, 2, 3, 7, 14, 21, 96, 112]
        case .images: [1, 2, 21, 96, 112]
        case .files: [3, 14]
        case .stickers: [7]
        }
    }
}

// Message metadata is an NSKeyedArchiver binary plist holding an NSDictionary
// of strings. LINE's own protocol defines the common keys (FILE_NAME,
// STKPKGID, ALT_TEXT, FLEX_JSON, REPLACE, MENTION, ...); unknown keys are kept
// as-is. Decode to a bounded Swift dictionary so a crafted blob cannot make the
// UI allocate without limit.
enum LINEMetadata {
    static let maximumEntries = 32

    static func decode(_ data: Data?) -> [String: String] {
        guard let data, !data.isEmpty, data.count <= 1_048_576 else { return [:] }
        guard let root = rootDictionary(data) else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in root {
            guard let name = key as? String, !name.isEmpty else { continue }
            guard result.count < maximumEntries else { break }
            guard let text = describe(value), !text.isEmpty else { continue }
            let trimmed = text.prefix(256)
            result[name] = trimmed.count < text.count ? trimmed + "…" : String(trimmed)
        }
        return result
    }

    // Current exports use secure coding, but older LINE builds and some
    // NSKeyedArchiver writers produce a classic archive. Accept both so a
    // metadata blob never hides the whole message body.
    private static func rootDictionary(_ data: Data) -> NSDictionary? {
        if let root = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSDictionary.self, from: data) {
            return root
        }
        return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? NSDictionary
    }

    // Values are normally strings, but archived metadata can also contain
    // arrays/dictionaries (for example a parsed MENTION body). Depth and item
    // counts are capped because NSKeyedUnarchiver can materialise cyclic
    // object graphs.
    private static func describe(_ value: Any, depth: Int = 0) -> String? {
        guard depth <= 2 else { return "…" }
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let date as NSDate:
            return Date(timeIntervalSince1970: date.timeIntervalSince1970)
                .formatted(date: .abbreviated, time: .standard)
        case let data as Data:
            return L("データ \(String(describing: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        case is NSNull:
            return nil
        case let array as NSArray:
            return array.prefix(8).map { describe($0, depth: depth + 1) ?? L("（空）") }
                .joined(separator: ", ")
        case let dictionary as NSDictionary:
            var parts: [String] = []
            for (key, value) in dictionary {
                guard parts.count < 8 else { break }
                guard let name = key as? String,
                      let text = describe(value, depth: depth + 1) else { continue }
                parts.append("\(name)=\(text)")
            }
            return parts.sorted().joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }

    private static func first(_ keys: [String], _ metadata: [String: String]) -> String? {
        for key in keys {
            if let value = metadata[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func labelled(_ label: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return label }
        return "\(label) \(value)"
    }

    // Short preview text for chat lists and bubbles.
    static func body(kind: LINEMessageKind, text: String?, metadata: [String: String]) -> String {
        if let text, !text.isEmpty { return text }
        switch kind {
        case .sticker: return L("[スタンプ]")
        case .image: return L("[画像]")
        case .video: return L("[動画]")
        case .audio: return L("[音声]")
        case .file: return labelled(L("[ファイル]"), first(["FILE_NAME", "fileName"], metadata))
        case .pdf: return labelled("[PDF]", first(["FILE_NAME", "fileName"], metadata))
        case .flex, .banner, .rich:
            return first(["ALT_TEXT", "indexableText"], metadata) ?? "[\(kind.title)]"
        case .contact:
            return labelled(L("[連絡先]"), first(["displayName", "DISPLAY_NAME", "mid", "MID"], metadata))
        case .link, .preview:
            return labelled("[\(kind.title)]", first(["title", "TITLE", "linkText", "altText", "linkUri", "url", "PREVIEW_URL"], metadata))
        case .album: return labelled(L("[アルバム]"), first(["albumName"], metadata))
        case .aggregate:
            if let total = first(["GTOTAL"], metadata) { return L("まとめ（\(String(describing: total))件）") }
            return L("[まとめ]")
        case .location: return labelled(L("[位置情報]"), first(["title", "address", "ADDRESS"], metadata))
        case .postNotification:
            return first(["ALT_TEXT", "indexableText"], metadata) ?? L("[通知]")
        default: return "[\(kind.title)]"
        }
    }

    // Human-readable extra lines shown inside the bubble.
    static func lines(kind: LINEMessageKind, metadata: [String: String]) -> [String] {
        var lines: [String] = []
        let fileName = first(["FILE_NAME", "fileName"], metadata)
        let fileSize = first(["FILE_SIZE", "fileSize"], metadata).flatMap(Int64.init)
        switch kind {
        case .file, .image, .video, .audio, .pdf, .extImage:
            if let fileName { lines.append(L("ファイル: \(String(describing: fileName))")) }
            if let fileSize {
                lines.append(L("サイズ: ") + ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
            }
            if let duration = first(["DURATION"], metadata).flatMap(Int64.init) {
                lines.append(L("長さ: \(String(describing: (duration / 1000).formatted()))秒"))
            }
        case .sticker:
            var parts: [String] = []
            if let package = metadata["STKPKGID"] { parts.append(L("パッケージ \(String(describing: package))")) }
            if let sticker = metadata["STKID"] { parts.append(L("ID \(String(describing: sticker))")) }
            if !parts.isEmpty { lines.append(L("スタンプ: ") + parts.joined(separator: " / ")) }
            if let text = metadata["STKTXT"], !text.isEmpty { lines.append(L("説明: \(String(describing: text))")) }
            if let version = metadata["STKVER"] { lines.append(L("バージョン: \(String(describing: version))")) }
            if let option = metadata["STKOPT"], !option.isEmpty { lines.append(L("アニメーション: \(String(describing: option))")) }
        case .contact:
            if let name = first(["displayName", "DISPLAY_NAME"], metadata) { lines.append(L("名前: \(String(describing: name))")) }
            if let mid = first(["mid", "MID"], metadata) { lines.append("MID: \(mid)") }
        case .link, .preview:
            if let uri = first(["linkUri", "url", "previewUrl", "PREVIEW_URL"], metadata) { lines.append(L("リンク: \(String(describing: uri))")) }
            if let title = first(["title", "TITLE", "linkText"], metadata) { lines.append(L("タイトル: \(String(describing: title))")) }
            if let description = first(["desc", "description", "subText", "altText"], metadata) { lines.append(L("説明: \(String(describing: description))")) }
        case .album:
            if let count = first(["mediaCount"], metadata).flatMap(Int64.init) {
                lines.append(L("メディア \(String(describing: count.formatted()))件"))
            }
        case .gift:
            if let product = first(["PRDID", "PRDTYPE"], metadata) { lines.append(L("商品: \(String(describing: product))")) }
            if let template = first(["MSGTPL"], metadata) { lines.append(L("テンプレート: \(String(describing: template))")) }
        case .location:
            if let latitude = first(["LATITUDE", "latitude"], metadata),
               let longitude = first(["LONGITUDE", "longitude"], metadata) {
                lines.append(L("緯度経度: \(String(describing: latitude)), \(String(describing: longitude))"))
            }
            if let address = first(["address", "ADDRESS"], metadata) { lines.append(L("住所: \(String(describing: address))")) }
        case .call:
            if let duration = first(["DURATION"], metadata).flatMap(Int64.init) {
                lines.append(L("通話時間: \(String(describing: (duration / 1000).formatted()))秒"))
            }
            if let type = first(["CALL_TYPE", "callType"], metadata) { lines.append(L("種類: \(String(describing: type))")) }
        case .flex, .banner, .rich:
            if let version = metadata["FLEX_VER"] { lines.append(L("Flexバージョン: \(String(describing: version))")) }
            if let tag = metadata["EFFECT_TAG"] { lines.append(L("エフェクト: \(String(describing: tag))")) }
        case .text:
            if metadata["REPLACE"] != nil { lines.append(L("絵文字（スタンプ絵文字）を含みます")) }
            if metadata["MENTION"] != nil { lines.append(L("メンションを含みます")) }
        default:
            break
        }
        if metadata["EDITED"] == "true" || metadata["UPDATED_TIME"] != nil { lines.append(L("編集済み")) }
        return lines
    }
}

// The SQLite3 module does not expose the SQLITE_TRANSIENT destructor macro.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Queries the extracted copies only. The databases are opened exactly like
// SQLiteDocument does: read-only, NOFOLLOW, query_only, trusted_schema=OFF,
// authorizer-restricted, with a per-query deadline.
actor LINEDataStore {
    static let pageSize = 100
    static let maximumMessageOffset = 100_000
    static let maximumSearchResults = 500
    static let queryBudgetSeconds: Double = 10

    let directory: URL
    let accountMID: String

    private var userNamesCache: [String: String]?
    private var groupInfoCache: [String: String]?
    private var talkMembersCache: [Int64: [String]]?
    private var talkReactionsCache: [String: [(reactor: String, emoji: String, isMine: Bool)]]?
    private var openChatMemberNamesCache: [Int64: String]?
    private var openChatMidNamesCache: [String: String]?
    private var openChatChatMIDsCache: Set<String>?
    private var openChatReactionsCache: [String: [(reactor: String, emoji: String, isMine: Bool)]]?
    private var readCountColumnCache: [String: Bool] = [:]

    init(directory: URL, accountMID: String) {
        self.directory = directory
        self.accountMID = accountMID
    }

    // MARK: Chat lists

    func chatSummaries(scope: LINEScope) throws -> [LINEChatSummary] {
        scope == .talk ? try talkChats() : try openChatChats()
    }

    private func talkChats() throws -> [LINEChatSummary] {
        let groups = try talkGroupNames()
        let members = try talkMembers()
        let names = try talkUserNames()
        let openChatMIDs = (try? openChatChatMIDs()) ?? []
        let counts = try withDatabase(role: "Line.sqlite") { database in
            try chatCounts(database)
        }
        return try withDatabase(role: "Line.sqlite") { database in
            try withStatement(database, sql: """
            SELECT Z_PK, coalesce(ZMID, ''), ZTYPE, ZUNREAD, coalesce(ZLASTMESSAGE, ''), ZLASTUPDATED
            FROM ZCHAT ORDER BY Z_PK
            """) { statement in
                var chats: [LINEChatSummary] = []
                while try step(statement, database: database) {
                    let pk = sqlite3_column_int64(statement, 0)
                    let mid = text(statement, column: 1, maximumBytes: 128)
                    // OpenChat rooms are also mirrored into Line.sqlite, but
                    // their messages live in LineSquare.sqlite. Keep them out
                    // of the talk list so they open through the OpenChat scope.
                    guard !openChatMIDs.contains(mid) else { continue }
                    let type = sqlite3_column_int64(statement, 2)
                    let unread = Int(sqlite3_column_int64(statement, 3))
                    let lastMessage = text(statement, column: 4, maximumBytes: 4096)
                    let updated = referenceDate(statement, column: 5)
                    let kind = LINEChatKind(type: type, mid: mid, accountMID: accountMID)
                    let chatMemberNames = members[pk] ?? []
                    let count = counts[pk] ?? 0
                    let unknownName = L("（名称不明）")
                    let name: String
                    switch kind {
                    case .selfChat:
                        name = L("自分")
                    case .oneToOne:
                        name = names[mid] ?? chatMemberNames.first ?? unknownName
                    case .group, .room, .unknown:
                        if let group = groups[mid], !group.isEmpty {
                            name = group
                        } else if !chatMemberNames.isEmpty {
                            name = chatMemberNames.prefix(3).joined(separator: L("、"))
                                + (chatMemberNames.count > 3 ? L(" 他\(String(describing: chatMemberNames.count - 3))人") : "")
                        } else {
                            name = unknownName
                        }
                    }
                    // A stale unnamed room with no messages is an OpenChat
                    // remnant that cannot be opened or named. Hide it instead
                    // of showing an empty unknown-name row.
                    guard name != unknownName || count > 0 else { continue }
                    chats.append(LINEChatSummary(id: pk, mid: mid, kind: kind, name: name,
                                                 memberNames: chatMemberNames, unread: unread,
                                                 messageCount: count,
                                                 lastMessage: lastMessage.isEmpty ? nil : lastMessage,
                                                 lastUpdated: updated))
                }
                return chats
            }
        }
    }

    private func openChatChats() throws -> [LINEChatSummary] {
        let memberNames = try openChatMemberNames()
        return try withDatabase(role: "LineSquare.sqlite") { database in
            try withStatement(database, sql: """
            SELECT Z_PK, coalesce(ZMID, ''), coalesce(ZNAME, ''), ZUNREAD, coalesce(ZLASTMESSAGE, ''), ZLASTUPDATED, ZMEMBERCOUNT
            FROM ZCHAT ORDER BY Z_PK
            """) { statement in
                var chats: [LINEChatSummary] = []
                while try step(statement, database: database) {
                    let pk = sqlite3_column_int64(statement, 0)
                    let mid = text(statement, column: 1, maximumBytes: 128)
                    let name = text(statement, column: 2, maximumBytes: 1024)
                    let unread = Int(sqlite3_column_int64(statement, 3))
                    let lastMessage = text(statement, column: 4, maximumBytes: 4096)
                    let updated = referenceDate(statement, column: 5)
                    let display = name.isEmpty ? (memberNames[pk] ?? L("（名称不明）")) : name
                    chats.append(LINEChatSummary(id: pk, mid: mid, kind: .room, name: display,
                                                 memberNames: [], unread: unread, messageCount: 0,
                                                 lastMessage: lastMessage.isEmpty ? nil : lastMessage,
                                                 lastUpdated: updated))
                }
                return chats
            }
        }
    }

    // MARK: Messages

    // Talk: rows without a sender reference are the account's own messages
    // (the account itself is not listed in ZUSER). OpenChat: the chat's ZME
    // row identifies the account's own member, so ownership is computed in SQL.
    // ZSQUAREMEMBER exposes the display name as ZDISPLAYNAME, not ZNAME.
    private static func messageSelect(scope: LINEScope, includeReadCount: Bool,
                                     extraColumns: String = "") -> String {
        let senderTable = scope == .talk ? "ZUSER" : "ZSQUAREMEMBER"
        let senderName = scope == .talk ? "u.ZNAME" : "u.ZDISPLAYNAME"
        let ownership = scope == .talk
            ? "CASE WHEN m.ZSENDER IS NULL THEN 1 ELSE 0 END"
            : "CASE WHEN m.ZSENDER IS NOT NULL AND m.ZSENDER = c.ZME THEN 1 ELSE 0 END"
        let readCount = includeReadCount ? ", coalesce(m.ZREADCOUNT, 0)" : ""
        return """
        SELECT m.Z_PK, m.ZTIMESTAMP, coalesce(m.ZTEXT, ''), m.ZCONTENTTYPE, coalesce(m.ZID, ''),
               \(senderName), m.ZCONTENTMETADATA, \(ownership)\(readCount)\(extraColumns)
        FROM ZMESSAGE m
        LEFT JOIN \(senderTable) u ON u.Z_PK = m.ZSENDER
        LEFT JOIN ZCHAT c ON c.Z_PK = m.ZCHAT
        """
    }

    private static func messageSQL(scope: LINEScope, includeReadCount: Bool) -> String {
        messageSelect(scope: scope, includeReadCount: includeReadCount)
    }

    // Older LINE databases and some generated fixtures have no ZREADCOUNT.
    // Probe once per database role and fall back to 0 instead of failing the
    // whole page.
    private func supportsReadCount(role: String) throws -> Bool {
        if let cached = readCountColumnCache[role] { return cached }
        let supported = try withDatabase(role: role) { database in
            do {
                return try withStatement(database, sql: "SELECT ZREADCOUNT FROM ZMESSAGE LIMIT 1") { _ in true }
            } catch {
                return false
            }
        }
        readCountColumnCache[role] = supported
        return supported
    }

    func messagePage(chatID: Int64, offset: Int, scope: LINEScope) throws -> LINEMessagePage {
        guard offset >= 0, offset <= Self.maximumMessageOffset else { throw RunnerError(localized: "表示できる範囲を超えています。") }
        let role = scope == .talk ? "Line.sqlite" : "LineSquare.sqlite"
        let includeReadCount = try supportsReadCount(role: role)
        let reactions = try reactions(scope: scope)
        let sql = Self.messageSQL(scope: scope, includeReadCount: includeReadCount) + """
        
        WHERE m.ZCHAT = ?
        ORDER BY m.ZTIMESTAMP DESC, m.Z_PK DESC
        LIMIT ? OFFSET ?
        """
        let rows = try withDatabase(role: role) { database in
            try withStatement(database, sql: sql) { statement in
                sqlite3_bind_int64(statement, 1, chatID)
                sqlite3_bind_int64(statement, 2, Int64(Self.pageSize + 1))
                sqlite3_bind_int64(statement, 3, Int64(offset))
                var result: [LINEMessage] = []
                var overflow = false
                while try step(statement, database: database) {
                    if result.count == Self.pageSize { overflow = true; break }
                    result.append(self.message(statement, scope: scope, reactions: reactions,
                                               includeReadCount: includeReadCount))
                }
                return (result, overflow)
            }
        }
        return LINEMessagePage(messages: try attachReplies(to: Array(rows.0.reversed()), scope: scope),
                               hasOlder: rows.1)
    }

    func searchMessages(chatID: Int64, term: String, scope: LINEScope) throws -> [LINEMessage] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 256 else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let role = scope == .talk ? "Line.sqlite" : "LineSquare.sqlite"
        let includeReadCount = try supportsReadCount(role: role)
        let reactions = try reactions(scope: scope)
        let sql = Self.messageSQL(scope: scope, includeReadCount: includeReadCount) + """

        WHERE m.ZCHAT = ? AND m.ZTEXT LIKE ? ESCAPE '\\'
        ORDER BY m.ZTIMESTAMP DESC, m.Z_PK DESC
        LIMIT ?
        """
        let messages: [LINEMessage] = try withDatabase(role: role) { database in
            try withStatement(database, sql: sql) { statement in
                sqlite3_bind_int64(statement, 1, chatID)
                // Wrap the escaped term so a word matches anywhere in the body;
                // LIKE without wildcards would only match the whole message.
                sqlite3_bind_text(statement, 2, "%\(escaped)%", -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 3, Int64(Self.maximumSearchResults))
                var result: [LINEMessage] = []
                while try step(statement, database: database) {
                    result.append(self.message(statement, scope: scope, reactions: reactions,
                                               includeReadCount: includeReadCount))
                }
                return Array(result.reversed())
            }
        }
        return try attachReplies(to: messages, scope: scope)
    }

    // MARK: Media gallery

    // Lists messages with images, files or stickers across the account (or a
    // single chat). The media itself is still read on demand by LINEMediaStore.
    func mediaMessages(scope: LINEScope, filter: LINEMediaFilter, chatID: Int64?,
                       offset: Int, limit: Int) throws -> LINEMediaMessagePage {
        guard offset >= 0, offset <= Self.maximumMessageOffset else { throw RunnerError(localized: "表示できる範囲を超えています。") }
        let pageSize = min(max(limit, 1), 200)
        let types = filter.contentTypes
        let placeholders = Array(repeating: "?", count: types.count).joined(separator: ",")
        let chatClause = chatID == nil ? "" : " AND m.ZCHAT = ?"
        let sql = Self.messageSelect(scope: scope, includeReadCount: false,
                                     extraColumns: ", m.ZCHAT, coalesce(c.ZMID, '')") + """

        WHERE m.ZCONTENTTYPE IN (\(placeholders))\(chatClause)
        ORDER BY m.ZTIMESTAMP DESC, m.Z_PK DESC
        LIMIT ? OFFSET ?
        """
        let role = scope == .talk ? "Line.sqlite" : "LineSquare.sqlite"
        let rows: ([LINEMediaMessage], Bool) = try withDatabase(role: role) { database in
            try withStatement(database, sql: sql) { statement in
                var parameter: Int32 = 1
                for type in types {
                    sqlite3_bind_int64(statement, parameter, type)
                    parameter += 1
                }
                if let chatID {
                    sqlite3_bind_int64(statement, parameter, chatID)
                    parameter += 1
                }
                sqlite3_bind_int64(statement, parameter, Int64(pageSize + 1))
                sqlite3_bind_int64(statement, parameter + 1, Int64(offset))
                var result: [LINEMediaMessage] = []
                var overflow = false
                while try step(statement, database: database) {
                    if result.count == pageSize { overflow = true; break }
                    let message = self.message(statement, scope: scope, reactions: [:],
                                               includeReadCount: false)
                    let chat = sqlite3_column_int64(statement, 8)
                    let chatMID = text(statement, column: 9, maximumBytes: 128)
                    result.append(LINEMediaMessage(id: message.id, chatID: chat,
                                                   chatMID: chatMID, message: message))
                }
                return (result, overflow)
            }
        }
        return LINEMediaMessagePage(items: rows.0, hasMore: rows.1)
    }

    // MARK: Row decoding

    private func message(_ statement: OpaquePointer, scope: LINEScope,
                         reactions: [String: [(reactor: String, emoji: String, isMine: Bool)]],
                         includeReadCount: Bool) -> LINEMessage {
        let pk = sqlite3_column_int64(statement, 0)
        let timestamp = sqlite3_column_int64(statement, 1)
        let text = self.text(statement, column: 2, maximumBytes: 8192)
        let contentType = sqlite3_column_int64(statement, 3)
        let messageMID = self.text(statement, column: 4, maximumBytes: 128)
        let senderName = self.text(statement, column: 5, maximumBytes: 512)
        let metadata = LINEMetadata.decode(blob(statement, column: 6))
        let isMine = sqlite3_column_int64(statement, 7) != 0
        let readCount = includeReadCount ? Int(sqlite3_column_int64(statement, 8)) : 0
        let kind = LINEMessageKind(contentType: contentType)
        let isSystem = kind.isSystemNotice || metadata["systemMessageTypeName"] != nil
        let replyToID = (metadata["replyOriginalMessageId"] ?? metadata["message_relation_server_message_id"])
            .flatMap { $0.isEmpty ? nil : $0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reactionList: [LINEMessageReaction] = []
        if let rows = reactions[messageMID], !messageMID.isEmpty {
            var grouped: [String: LINEMessageReaction] = [:]
            var order: [String] = []
            for row in rows {
                if let existing = grouped[row.emoji] {
                    grouped[row.emoji] = LINEMessageReaction(emoji: row.emoji, count: existing.count + 1,
                                                            isMine: existing.isMine || row.isMine,
                                                            reactorNames: existing.reactorNames + [row.reactor])
                } else {
                    order.append(row.emoji)
                    grouped[row.emoji] = LINEMessageReaction(emoji: row.emoji, count: 1, isMine: row.isMine,
                                                            reactorNames: [row.reactor])
                }
            }
            reactionList = order.compactMap { grouped[$0] }
        }
        return LINEMessage(id: pk,
                           date: Self.date(timestampMilliseconds: timestamp),
                           messageMID: messageMID.isEmpty ? nil : messageMID,
                           senderName: senderName.isEmpty ? nil : senderName,
                           isMine: isMine,
                           isSystem: isSystem,
                           kind: kind,
                           text: trimmed.isEmpty ? nil : text,
                           metadata: metadata,
                           reactions: reactionList,
                           replyToID: replyToID,
                           replyTo: nil,
                           readCount: max(readCount, 0))
    }

    // Resolves reply targets for a page in one query. replyOriginalMessageId
    // and message_relation_server_message_id live inside ZCONTENTMETADATA, so
    // a self-join is not possible without decoding the plist first.
    private func attachReplies(to messages: [LINEMessage], scope: LINEScope) throws -> [LINEMessage] {
        let ids = Array(Set(messages.compactMap(\.replyToID))).sorted()
        guard !ids.isEmpty else { return messages }
        let senderTable = scope == .talk ? "ZUSER" : "ZSQUAREMEMBER"
        let senderName = scope == .talk ? "u.ZNAME" : "u.ZDISPLAYNAME"
        let ownership = scope == .talk
            ? "CASE WHEN m.ZSENDER IS NULL THEN 1 ELSE 0 END"
            : "CASE WHEN m.ZSENDER IS NOT NULL AND m.ZSENDER = c.ZME THEN 1 ELSE 0 END"
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT coalesce(m.ZID, ''), coalesce(m.ZTEXT, ''), m.ZCONTENTTYPE, m.ZCONTENTMETADATA,
               \(senderName), \(ownership)
        FROM ZMESSAGE m
        LEFT JOIN \(senderTable) u ON u.Z_PK = m.ZSENDER
        LEFT JOIN ZCHAT c ON c.Z_PK = m.ZCHAT
        WHERE m.ZID IN (\(placeholders))
        LIMIT 1000
        """
        let previews: [String: LINEReplyPreview] = try withDatabase(role: scope == .talk ? "Line.sqlite" : "LineSquare.sqlite") { database in
            try withStatement(database, sql: sql) { statement in
                for (index, id) in ids.enumerated() {
                    sqlite3_bind_text(statement, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
                }
                var result: [String: LINEReplyPreview] = [:]
                while try step(statement, database: database) {
                    let id = text(statement, column: 0, maximumBytes: 128)
                    guard !id.isEmpty else { continue }
                    let originalText = text(statement, column: 1, maximumBytes: 8192)
                    let contentType = sqlite3_column_int64(statement, 2)
                    let metadata = LINEMetadata.decode(blob(statement, column: 3))
                    let sender = text(statement, column: 4, maximumBytes: 512)
                    let isMine = sqlite3_column_int64(statement, 5) != 0
                    let kind = LINEMessageKind(contentType: contentType)
                    let body = LINEMetadata.body(kind: kind,
                                                 text: originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : originalText,
                                                 metadata: metadata)
                    result[id] = LINEReplyPreview(messageID: id,
                                                  senderName: sender.isEmpty ? (isMine ? L("自分") : nil) : sender,
                                                  body: body)
                }
                return result
            }
        }
        return messages.map { message in
            guard let id = message.replyToID, let preview = previews[id] else { return message }
            return message.withReplyTo(preview)
        }
    }

    // ZMESSAGE.ZTIMESTAMP is Unix milliseconds in current exports. Older
    // databases (and a few generated fixtures) stored seconds; normalise both
    // so the displayed date cannot silently land in 1970.
    private static func date(timestampMilliseconds raw: Int64) -> Date {
        let milliseconds = raw > 100_000_000_000 ? raw : raw * 1000
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    // MARK: Caches

    private func talkUserNames() throws -> [String: String] {
        if let userNamesCache { return userNamesCache }
        let result: [String: String] = try withDatabase(role: "Line.sqlite") { database in
            try withStatement(database, sql: "SELECT coalesce(ZMID, ''), coalesce(ZNAME, '') FROM ZUSER") { statement in
                var names: [String: String] = [:]
                while try step(statement, database: database) {
                    let mid = text(statement, column: 0, maximumBytes: 128)
                    let name = text(statement, column: 1, maximumBytes: 512)
                    if !mid.isEmpty { names[mid] = name.isEmpty ? mid : name }
                }
                return names
            }
        }
        userNamesCache = result
        return result
    }

    private func talkGroupNames() throws -> [String: String] {
        if let groupInfoCache { return groupInfoCache }
        var groups: [String: String] = [:]
        // ZGROUP lives in Line.sqlite and is the authoritative group name in
        // current exports. UnifiedGroup.sqlite supplements datasets where the
        // group row is absent.
        try withDatabase(role: "Line.sqlite") { database in
            guard try hasTable(database, "ZGROUP") else { return }
            try withStatement(database, sql: "SELECT coalesce(ZID, ''), coalesce(ZNAME, '') FROM ZGROUP") { statement in
                while try step(statement, database: database) {
                    let id = text(statement, column: 0, maximumBytes: 128)
                    let name = text(statement, column: 1, maximumBytes: 1024)
                    if !id.isEmpty, !name.isEmpty { groups[id] = name }
                }
            }
        }
        if let url = stagedURL(role: "UnifiedGroup.sqlite") {
            try withDatabase(url: url) { database in
                guard try hasTable(database, "ZUNIFIEDGROUP") else { return }
                try withStatement(database, sql: "SELECT coalesce(ZID, ''), coalesce(ZNAME, '') FROM ZUNIFIEDGROUP") { statement in
                    while try step(statement, database: database) {
                        let id = text(statement, column: 0, maximumBytes: 128)
                        let name = text(statement, column: 1, maximumBytes: 1024)
                        if !id.isEmpty, !name.isEmpty, groups[id] == nil { groups[id] = name }
                    }
                }
            }
        }
        groupInfoCache = groups
        return groups
    }

    private func talkMembers() throws -> [Int64: [String]] {
        if let talkMembersCache { return talkMembersCache }
        let names = try talkUserNames()
        let result: [Int64: [String]] = try withDatabase(role: "Line.sqlite") { database in
            guard try hasTable(database, "Z_1MEMBERS"), try hasTable(database, "ZUSER") else { return [:] }
            return try withStatement(database, sql: """
            SELECT g.Z_1CHATS, coalesce(u.ZMID, ''), coalesce(u.ZNAME, '')
            FROM Z_1MEMBERS g JOIN ZUSER u ON u.Z_PK = g.Z_12MEMBERS ORDER BY g.Z_1CHATS, u.Z_PK
            """) { statement in
                var members: [Int64: [String]] = [:]
                while try step(statement, database: database) {
                    let chat = sqlite3_column_int64(statement, 0)
                    let mid = text(statement, column: 1, maximumBytes: 128)
                    let name = text(statement, column: 2, maximumBytes: 512)
                    if !mid.isEmpty {
                        members[chat, default: []].append(name.isEmpty ? (names[mid] ?? mid) : name)
                    }
                }
                return members
            }
        }
        talkMembersCache = result
        return result
    }

    private func talkReactionsTable() throws -> [String: [(reactor: String, emoji: String, isMine: Bool)]] {
        if let talkReactionsCache { return talkReactionsCache }
        let names = try talkUserNames()
        guard let url = stagedURL(role: "MessageExt.sqlite") else { return [:] }
        let result: [String: [(String, String, Bool)]] = try withDatabase(url: url) { database in
            guard try hasTable(database, "ZMESSAGEREACTION") else { return [:] }
            return try withStatement(database, sql: "SELECT coalesce(ZMESSAGEID, ''), coalesce(ZREACTORMID, ''), ZREACTIONTYPE, coalesce(ZCUSTOMREACTION, '') FROM ZMESSAGEREACTION") { statement in
                var table: [String: [(String, String, Bool)]] = [:]
                while try step(statement, database: database) {
                    let messageID = text(statement, column: 0, maximumBytes: 128)
                    let reactorMID = text(statement, column: 1, maximumBytes: 128)
                    let type = sqlite3_column_int64(statement, 2)
                    let custom = text(statement, column: 3, maximumBytes: 32)
                    let emoji = custom.isEmpty ? LINEReactionType.emoji(for: type) : custom
                    guard !messageID.isEmpty, let emoji else { continue }
                    table[messageID, default: []].append((names[reactorMID] ?? reactorMID, emoji, reactorMID == accountMID))
                }
                return table
            }
        }
        talkReactionsCache = result
        return result
    }

    // OpenChat rooms are mirrored into Line.sqlite, but only LineSquare.sqlite
    // holds their messages. Their chat MID is the stable link between the two
    // databases.
    private func openChatChatMIDs() throws -> Set<String> {
        if let openChatChatMIDsCache { return openChatChatMIDsCache }
        guard stagedURL(role: "LineSquare.sqlite") != nil else {
            openChatChatMIDsCache = []
            return []
        }
        let result: Set<String> = try withDatabase(role: "LineSquare.sqlite") { database in
            guard try hasTable(database, "ZCHAT") else { return [] }
            return try withStatement(database, sql: "SELECT coalesce(ZMID, '') FROM ZCHAT") { statement in
                var mids = Set<String>()
                while try step(statement, database: database) {
                    let mid = text(statement, column: 0, maximumBytes: 128)
                    if !mid.isEmpty { mids.insert(mid) }
                }
                return mids
            }
        }
        openChatChatMIDsCache = result
        return result
    }

    private func openChatMemberNames() throws -> [Int64: String] {
        if let openChatMemberNamesCache { return openChatMemberNamesCache }
        let result: [Int64: String] = try withDatabase(role: "LineSquare.sqlite") { database in
            guard try hasTable(database, "ZSQUAREMEMBER") else { return [:] }
            return try withStatement(database, sql: "SELECT Z_PK, coalesce(ZDISPLAYNAME, ''), coalesce(ZMID, '') FROM ZSQUAREMEMBER") { statement in
                var rows: [Int64: String] = [:]
                while try step(statement, database: database) {
                    let pk = sqlite3_column_int64(statement, 0)
                    let display = text(statement, column: 1, maximumBytes: 512)
                    let mid = text(statement, column: 2, maximumBytes: 128)
                    if let name = display.isEmpty ? (mid.isEmpty ? nil : mid) : display { rows[pk] = name }
                }
                return rows
            }
        }
        openChatMemberNamesCache = result
        return result
    }

    private func openChatMidNames() throws -> [String: String] {
        if let openChatMidNamesCache { return openChatMidNamesCache }
        let result: [String: String] = try withDatabase(role: "LineSquare.sqlite") { database in
            guard try hasTable(database, "ZSQUAREMEMBER") else { return [:] }
            return try withStatement(database, sql: "SELECT coalesce(ZMID, ''), coalesce(ZDISPLAYNAME, '') FROM ZSQUAREMEMBER") { statement in
                var rows: [String: String] = [:]
                while try step(statement, database: database) {
                    let mid = text(statement, column: 0, maximumBytes: 128)
                    let display = text(statement, column: 1, maximumBytes: 512)
                    if !mid.isEmpty { rows[mid] = display.isEmpty ? mid : display }
                }
                return rows
            }
        }
        openChatMidNamesCache = result
        return result
    }

    private func openChatReactionsTable() throws -> [String: [(reactor: String, emoji: String, isMine: Bool)]] {
        if let openChatReactionsCache { return openChatReactionsCache }
        let names = try openChatMidNames()
        let result: [String: [(String, String, Bool)]] = try withDatabase(role: "LineSquare.sqlite") { database in
            guard try hasTable(database, "ZMESSAGEREACTION") else { return [:] }
            return try withStatement(database, sql: "SELECT coalesce(ZMESSAGEID, ''), coalesce(ZREACTORMID, ''), ZREACTIONTYPE, coalesce(ZCUSTOMREACTION, '') FROM ZMESSAGEREACTION") { statement in
                var table: [String: [(String, String, Bool)]] = [:]
                while try step(statement, database: database) {
                    let messageID = text(statement, column: 0, maximumBytes: 128)
                    let reactorMID = text(statement, column: 1, maximumBytes: 128)
                    let type = sqlite3_column_int64(statement, 2)
                    let custom = text(statement, column: 3, maximumBytes: 32)
                    let emoji = custom.isEmpty ? LINEReactionType.emoji(for: type) : custom
                    guard !messageID.isEmpty, let emoji else { continue }
                    table[messageID, default: []].append((names[reactorMID] ?? reactorMID, emoji, false))
                }
                return table
            }
        }
        openChatReactionsCache = result
        return result
    }

    private func reactions(scope: LINEScope) throws -> [String: [(reactor: String, emoji: String, isMine: Bool)]] {
        try scope == .talk ? talkReactionsTable() : openChatReactionsTable()
    }

    // MARK: SQLite plumbing (hardening mirrors SQLiteDocument)

    // Optional tables are absent in older LINE versions and in some
    // OpenChat-only exports. Probe sqlite_master instead of failing the whole
    // chat list because a single auxiliary table is missing.
    private func hasTable(_ database: OpaquePointer, _ name: String) throws -> Bool {
        try withStatement(database, sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1") { statement in
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
            return try step(statement, database: database)
        }
    }

    private func stagedURL(role: String) -> URL? {
        let url = directory.appendingPathComponent(role)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func withDatabase<T>(role: String, operation: (OpaquePointer) throws -> T) throws -> T {
        guard let url = stagedURL(role: role) else { throw RunnerError(localized: "LINEデータの「\(String(describing: role))」が見つかりません。") }
        return try withDatabase(url: url, operation: operation)
    }

    private func withDatabase<T>(url: URL, operation: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard let path = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(path) }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let connection { sqlite3_close(connection) } }
        guard result == SQLITE_OK, let database = connection else { throw databaseError(connection) }
        sqlite3_busy_timeout(database, 500)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 8 * 1024 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 1_048_576)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(database, SQLITE_LIMIT_EXPR_DEPTH, 100)
        sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(database, SQLITE_LIMIT_VDBE_OP, 1_000_000)
        let budget = QueryBudget()
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<QueryBudget>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            withExtendedLifetime(budget) {}
        }
        guard sqlite3_exec(database, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA cache_size=-2048;", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        sqlite3_set_authorizer(database, { _, action, _, argument, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_FUNCTION:
                return argument.map { String(cString: $0).lowercased() == "load_extension" } == true ? SQLITE_DENY : SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil)
        return try operation(database)
    }

    private func withStatement<T>(_ database: OpaquePointer, sql: String, operation: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard result == SQLITE_OK, let statement, sqlite3_stmt_readonly(statement) != 0 else { throw databaseError(database) }
        return try operation(statement)
    }

    private func step(_ statement: OpaquePointer, database: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(database)
        }
    }

    private func chatCounts(_ database: OpaquePointer) throws -> [Int64: Int] {
        try withStatement(database, sql: "SELECT ZCHAT, COUNT(*) FROM ZMESSAGE GROUP BY ZCHAT") { statement in
            var counts: [Int64: Int] = [:]
            while try step(statement, database: database) {
                counts[sqlite3_column_int64(statement, 0)] = Int(sqlite3_column_int64(statement, 1))
            }
            return counts
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32, maximumBytes: Int = 1024) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: min(count, maximumBytes)), as: UTF8.self) + (count > maximumBytes ? "…" : "")
    }

    private func blob(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= 1_048_576, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    // Core Data TIMESTAMP: seconds since 2001-01-01.
    private func referenceDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }

    private func databaseError(_ database: OpaquePointer?) -> RunnerError {
        if Task.isCancelled { return RunnerError(localized: "LINEデータの読み取りを中止しました。") }
        if let database, sqlite3_errcode(database) == SQLITE_INTERRUPT {
            return RunnerError(localized: "LINEデータの処理時間が上限（\(String(describing: Int(Self.queryBudgetSeconds).formatted()))秒）を超えました。")
        }
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? L("データベースを開けません。")
        return RunnerError(localized: "LINEデータ: \(String(describing: message))")
    }

    private final class QueryBudget {
        let deadline = ProcessInfo.processInfo.systemUptime + queryBudgetSeconds
        var shouldStop: Bool {
            let cancelled = withUnsafeCurrentTask { $0?.isCancelled ?? false }
            return cancelled || ProcessInfo.processInfo.systemUptime >= deadline
        }
    }
}
