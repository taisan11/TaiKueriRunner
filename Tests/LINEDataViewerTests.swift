import XCTest
import SQLite3
import Compression
@testable import RunnerCore

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LINEDataViewerTests: XCTestCase {
    private let accountMID = "uSELF0000000000000000000000000000001"

    // MARK: Stored ZIP reader

    func testStoredArchiveWriterRoundTripsThroughReader() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: true)
        let archive = root.appendingPathComponent("export.zip")
        try StoredZIPArchive.write(directory: root.appendingPathComponent("Data"), to: archive,
                                   maximumBytes: ApplicationDataExport.maximumArchiveBytes, report: Data("{}".utf8))
        let original = try Data(contentsOf: payload.line)
        let lineEntryName = "Data/Library/Application Support/PrivateStore/P_\(accountMID)/Messages/Line.sqlite"
        try StoredZIPReader.withArchive(path: archive.path) { zip in
            let entries = zip.entries
            XCTAssertTrue(entries.contains { $0.name == lineEntryName })
            XCTAssertTrue(entries.contains { $0.name == "ExportReport.json" })
            XCTAssertTrue(entries.allSatisfy { $0.method == 0 })
            // The writer zeroes local header sizes and appends data
            // descriptors; extraction must rely on the central directory.
            try zip.extract(zip.entry(named: lineEntryName)!,
                            to: root.appendingPathComponent("copy.sqlite"))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy.sqlite")), original)
    }

    func testDeflateEntryIsExtractedAndCRCVerified() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("LINEのDEFLATE圧縮エントリの内容です。".utf8)
        let deflated = try deflate(payload)
        let name = Data("Data/Library/Application Support/PrivateStore/P_x/Messages/Line.sqlite".utf8)
        let payloadOffset = 30 + name.count
        var zip = Data()
        zip.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        zip.zip16(20); zip.zip16(0); zip.zip16(8)
        zip.zip16(0); zip.zip16(0x0021)
        zip.zip32(Self.crc32(payload)); zip.zip32(UInt32(deflated.count)); zip.zip32(UInt32(payload.count))
        zip.zip16(UInt16(name.count)); zip.zip16(0); zip.append(name); zip.append(deflated)
        zip.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        zip.zip16(0x0314); zip.zip16(20); zip.zip16(0); zip.zip16(8)
        zip.zip16(0); zip.zip16(0x0021)
        zip.zip32(Self.crc32(payload)); zip.zip32(UInt32(deflated.count)); zip.zip32(UInt32(payload.count))
        zip.zip16(UInt16(name.count)); zip.zip16(0); zip.zip16(0); zip.zip16(0); zip.zip16(0)
        zip.zip32(0o100600 << 16); zip.zip32(0); zip.append(name)
        let centralSize = zip.count - payloadOffset - deflated.count
        zip.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        zip.zip16(0); zip.zip16(0); zip.zip16(1); zip.zip16(1)
        zip.zip32(UInt32(centralSize)); zip.zip32(UInt32(payloadOffset + deflated.count)); zip.zip16(0)
        let archiveURL = root.appendingPathComponent("deflate.zip")
        try zip.write(to: archiveURL)
        try StoredZIPReader.withArchive(path: archiveURL.path) { read in
            XCTAssertEqual(read.entries.count, 1)
            let entry = try XCTUnwrap(read.entries.first)
            XCTAssertEqual(entry.method, 8)
            try read.extract(entry, to: root.appendingPathComponent("out.sqlite"))
            XCTAssertEqual(try read.read(entry, maximumBytes: 1024), payload)
            XCTAssertEqual(try StoredZIPReader.readEntry(path: archiveURL.path, entry: entry, maximumBytes: 1024), payload)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("out.sqlite")), payload)
        // A corrupted deflate payload must fail instead of writing output.
        var broken = zip
        broken[payloadOffset] ^= 0xff
        let brokenURL = root.appendingPathComponent("broken.zip")
        try broken.write(to: brokenURL)
        XCTAssertThrowsError(try StoredZIPReader.withArchive(path: brokenURL.path) { read in
            try read.extract(try XCTUnwrap(read.entries.first), to: root.appendingPathComponent("broken.sqlite"))
        })
    }

    func testReaderRejectsNonArchivesAndUnsafeNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("plain.txt")
        try Data("ただのテキスト".utf8).write(to: text)
        XCTAssertThrowsError(try StoredZIPReader.withArchive(path: text.path) { _ in })
        // EOCD with a traversal entry name is refused at listing time.
        let evil = try zipWithEntry(name: "../escape.txt", data: Data("x".utf8))
        let evilURL = root.appendingPathComponent("evil.zip")
        try evil.write(to: evilURL)
        XCTAssertThrowsError(try StoredZIPReader.withArchive(path: evilURL.path) { _ in })
    }

    // MARK: Staging cleanup

    func testStagingNamesAreRecognizedForCacheCleanup() {
        XCTAssertTrue(AppCacheStore.isStagingName("LINEDataPreview-\(UUID().uuidString)"))
        XCTAssertTrue(AppCacheStore.isStagingName("LINEMediaShare-\(UUID().uuidString)"))
        XCTAssertFalse(AppCacheStore.isStagingName("LINEDataPreview-not-a-uuid"))
    }

    // MARK: Live App Group container mode

    func testLiveContainerInspectionFindsAccountAndExtractionCopiesDatabases() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("group-container", isDirectory: true)
        let payload = try makeMessagesDirectory(directory: container, includeOpenChat: true, withSidecars: true)
        try populateTalkDatabase(line: payload.line, unified: payload.unified, messageExt: payload.messageExt)
        try populateOpenChatDatabase(square: payload.square)
        let summary = try XCTUnwrap(LINEDataStaging.inspect(container: container.path, access: LINEDataStaging.directAccess()))
        XCTAssertEqual(summary.accountMID, accountMID)
        XCTAssertTrue(summary.hasOpenChat)
        XCTAssertGreaterThan(summary.talkBytes, 0)
        // A container without the PrivateStore structure is not LINE data.
        let other = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        XCTAssertNil(try LINEDataStaging.inspect(container: other.path, access: LINEDataStaging.directAccess()))
        // Several accounts: the sorted first folder wins.
        let extra = container.appendingPathComponent("Library/Application Support/PrivateStore/P_uAAA0000000000000000000000000000000", isDirectory: true)
            .appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("SQLite format 3\0".utf8).write(to: extra.appendingPathComponent("Line.sqlite"))
        XCTAssertEqual(try LINEDataStaging.inspect(container: container.path, access: LINEDataStaging.directAccess())?.accountMID, "uAAA0000000000000000000000000000000")

        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try LINEDataStaging.extract(messages: payload.messages.path, summary: summary, includeOpenChat: true, to: staging, access: LINEDataStaging.directAccess())
        for role in ["Line.sqlite", "Line.sqlite-wal", "UnifiedGroup.sqlite", "MessageExt.sqlite", "LineSquare.sqlite"] {
            let source = payload.messages.appendingPathComponent(role), copy = staging.appendingPathComponent(role)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), role)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: copy))
        }
        // OpenChat is omitted when not requested; other roles remain complete.
        let limited = root.appendingPathComponent("staging-limited", isDirectory: true)
        try FileManager.default.createDirectory(at: limited, withIntermediateDirectories: false)
        try LINEDataStaging.extract(messages: payload.messages.path, summary: summary, includeOpenChat: false, to: limited, access: LINEDataStaging.directAccess())
        XCTAssertFalse(FileManager.default.fileExists(atPath: limited.appendingPathComponent("LineSquare.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: limited.appendingPathComponent("Line.sqlite").path))
    }

    // A sandbox denial must propagate so the shared per-path retry can engage.
    // The previous implementation swallowed stat failures, which made unreadable
    // databases look like missing ones ("この共有フォルダにLINEのメッセージDBがありません").
    func testLiveContainerPermissionDenialPropagatesInsteadOfLookingMissing() throws {
        let denied = LINEDataStaging.LINEStagingAccess(
            listDirectory: { _ in throw POSIXError(POSIXErrorCode.EACCES) },
            regularFileSize: { _ in throw POSIXError(POSIXErrorCode.EACCES) },
            copyFile: { _, _, _ in throw POSIXError(POSIXErrorCode.EACCES) })
        XCTAssertThrowsError(try LINEDataStaging.inspect(container: "/var/Containers/Shared/AppGroup/X", access: denied))
        // ENOENT stays a plain "not LINE data" answer.
        let missing = LINEDataStaging.LINEStagingAccess(
            listDirectory: { _ in throw POSIXError(POSIXErrorCode.ENOENT) },
            regularFileSize: { _ in throw POSIXError(POSIXErrorCode.ENOENT) },
            copyFile: { _, _, _ in throw POSIXError(POSIXErrorCode.ENOENT) })
        XCTAssertNil(try LINEDataStaging.inspect(container: "/var/Containers/Shared/AppGroup/X", access: missing))
    }

    func testLiveContainerExtractionRejectsNonSQLiteAndLinkedDatabases() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The main database must actually contain SQLite data after copying.
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try Data(repeating: 0x41, count: 256).write(to: payload.line)
        let summary = try XCTUnwrap(LINEDataStaging.inspect(container: root.appendingPathComponent("Data").path, access: LINEDataStaging.directAccess()))
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LINEDataStaging.extract(messages: payload.messages.path, summary: summary, includeOpenChat: false, to: staging, access: LINEDataStaging.directAccess()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("MessageExt.sqlite").path))
        // A linked Line.sqlite is never treated as the chat database.
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let linkPayload = try makeMessagesDirectory(directory: linked, includeOpenChat: false, withSidecars: false)
        try FileManager.default.removeItem(at: linkPayload.line)
        try FileManager.default.createSymbolicLink(at: linkPayload.line, withDestinationURL: payload.unified)
        XCTAssertThrowsError(try LINEDataStaging.inspect(container: linked.path, access: LINEDataStaging.directAccess()))
    }

    // The staging snapshot is an APFS clone where possible, so a multi-GB
    // database costs no extra disk and no read pass. The copy must stay
    // private and independent of later writes to the source.
    func testStagingCloneIsCopyOnWriteAndPrivate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Line.sqlite")
        let payload = Data("SQLite format 3\0".utf8) + Data(repeating: 0x41, count: 1 << 20)
        try payload.write(to: source)
        let destination = root.appendingPathComponent("clone.sqlite")
        let cloned = try LINEDataStaging.cloneFileIfPossible(source: source.path, expectedSize: payload.count, to: destination)
        XCTAssertTrue(cloned, "host tests run on APFS; clonefile should be available")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Copy-on-write: rewriting the source must not change the clone.
        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        // A source whose size no longer matches is not cloned; the caller
        // reports the "LINEを終了してから" error.
        XCTAssertFalse(try LINEDataStaging.cloneFileIfPossible(
            source: source.path, expectedSize: payload.count,
            to: root.appendingPathComponent("clone2.sqlite")))
    }

    func testFileAccessManagerRefusesNonAppGroupContainerPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager()
        let outside = root.appendingPathComponent("outside-container").path
        do {
            _ = try await manager.readLINEArchiveSummary(containerPath: outside)
            XCTFail("Path outside the App Group root accepted")
        } catch {}
        do {
            _ = try await manager.stageLINEData(containerPath: outside, summary: LINEArchiveSummary(accountMID: "uX", talkBytes: 1, openChatBytes: 0), includeOpenChat: false)
            XCTFail("Path outside the App Group root accepted for staging")
        } catch {}
        let grants = await manager.currentGrants()
        XCTAssertTrue(grants.isEmpty)
    }

    // MARK: Store queries

    func testTalkChatsNamesMessagesReactionsAndSearch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line, unified: payload.unified, messageExt: payload.messageExt)
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        XCTAssertEqual(chats.count, 4)
        let byMID = Dictionary(uniqueKeysWithValues: chats.map { ($0.mid, $0) })
        XCTAssertEqual(byMID[accountMID]?.kind, .selfChat)
        XCTAssertEqual(byMID[accountMID]?.name, "自分")
        XCTAssertEqual(byMID["uALICE"]?.kind, .oneToOne)
        XCTAssertEqual(byMID["uALICE"]?.name, "アリス")
        XCTAssertEqual(byMID["uALICE"]?.messageCount, 3)
        XCTAssertEqual(byMID["uALICE"]?.unread, 2)
        XCTAssertEqual(byMID["cGROUP"]?.kind, .group)
        XCTAssertEqual(byMID["cGROUP"]?.name, "アリス、ボブ")
        XCTAssertEqual(byMID["cNAMED"]?.name, "開拓者グループ")

        let alice = try XCTUnwrap(byMID["uALICE"])
        let page1 = try await store.messagePage(chatID: alice.id, offset: 0, scope: .talk)
        XCTAssertFalse(page1.hasOlder)
        XCTAssertEqual(page1.messages.map(\.text), ["こんにちは", "こちらこそ", "確認します"])
        // ZSENDER NULL marks the account's own message; ZUSER rows are others.
        XCTAssertEqual(page1.messages.map(\.isMine), [false, true, false])
        XCTAssertEqual(page1.messages.map(\.senderName), ["アリス", nil, "アリス"])
        XCTAssertEqual(page1.messages.last?.reactions.first?.emoji, "👍")
        XCTAssertEqual(page1.messages.last?.reactions.first?.count, 2)
        XCTAssertEqual(page1.messages.last?.reactions.first?.isMine, true)
        // Older schemas without ZREADCOUNT still load with an unread count.
        XCTAssertEqual(page1.messages.map(\.readCount), [0, 0, 0])

        let results = try await store.searchMessages(chatID: alice.id, term: "こんにちは", scope: .talk)
        XCTAssertEqual(results.map(\.text), ["こんにちは"])
        // Partial words match too.
        let partial = try await store.searchMessages(chatID: alice.id, term: "んにち", scope: .talk)
        XCTAssertEqual(partial.map(\.text), ["こんにちは"])
        // LIKE wildcards are escaped.
        let wildcard = try await store.searchMessages(chatID: alice.id, term: "100%", scope: .talk)
        XCTAssertTrue(wildcard.isEmpty)
    }

    func testReadCountIsReadWhenTheColumnExists() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        try withDatabase(payload.line) { database in
            try execute(database, "ALTER TABLE ZMESSAGE ADD COLUMN ZREADCOUNT INTEGER;")
            try execute(database, "UPDATE ZMESSAGE SET ZREADCOUNT = 1 WHERE ZID = 'm10';")
            try execute(database, "UPDATE ZMESSAGE SET ZREADCOUNT = 2 WHERE ZID = 'm12';")
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        let alice = try XCTUnwrap(chats.first { $0.mid == "uALICE" })
        let page = try await store.messagePage(chatID: alice.id, offset: 0, scope: .talk)
        XCTAssertEqual(page.messages.map(\.readCount), [1, 0, 2])
        // A word matches anywhere in the body, and read counts are included
        // in search results too.
        let results = try await store.searchMessages(chatID: alice.id, term: "確認", scope: .talk)
        XCTAssertEqual(results.map(\.text), ["確認します"])
        XCTAssertEqual(results.map(\.readCount), [2])
    }

    func testMessageKindsStickerFileAndSystemNotices() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line, unified: payload.unified, messageExt: payload.messageExt)
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        let group = try XCTUnwrap(chats.first { $0.mid == "cNAMED" })
        let page = try await store.messagePage(chatID: group.id, offset: 0, scope: .talk)
        XCTAssertEqual(page.messages.map(\.kind), [.sticker, .file, .text, .text])
        let sticker = page.messages[0]
        XCTAssertEqual(sticker.body, "[スタンプ]")
        XCTAssertTrue(sticker.metadataLines.contains { $0.contains("パッケージ 23812158") })
        let file = page.messages[1]
        XCTAssertEqual(file.body, "[ファイル] 貸家ちらし.pages")
        XCTAssertTrue(file.metadataLines.contains { $0.hasPrefix("サイズ:") })
        let unsent = page.messages[3]
        XCTAssertTrue(unsent.isSystem)
        XCTAssertEqual(unsent.body, "アリスがメッセージの送信を取り消しました")
        XCTAssertFalse(unsent.isMine)
    }

    func testMediaGalleryListsImagesFilesAndStickersWithPaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)

        let all = try await store.mediaMessages(scope: .talk, filter: .all, chatID: nil,
                                                offset: 0, limit: 100)
        // Newest first: the file is newer than the sticker; text/system rows
        // never appear in the gallery.
        XCTAssertEqual(all.items.map(\.message.kind), [.file, .sticker])
        XCTAssertEqual(all.items.map(\.chatMID), ["cNAMED", "cNAMED"])
        XCTAssertFalse(all.hasMore)

        let files = try await store.mediaMessages(scope: .talk, filter: .files, chatID: nil,
                                                  offset: 0, limit: 100)
        XCTAssertEqual(files.items.map(\.message.body), ["[ファイル] 貸家ちらし.pages"])
        let stickers = try await store.mediaMessages(scope: .talk, filter: .stickers, chatID: nil,
                                                     offset: 0, limit: 100)
        XCTAssertEqual(stickers.items.map(\.message.kind), [.sticker])
        XCTAssertEqual(stickers.items.first?.chatID, 4)

        // Paging keeps the same ordering and reports the final page.
        let first = try await store.mediaMessages(scope: .talk, filter: .all, chatID: 4,
                                                  offset: 0, limit: 1)
        XCTAssertEqual(first.items.map(\.message.kind), [.file])
        XCTAssertTrue(first.hasMore)
        let second = try await store.mediaMessages(scope: .talk, filter: .all, chatID: 4,
                                                   offset: 1, limit: 1)
        XCTAssertEqual(second.items.map(\.message.kind), [.sticker])
        XCTAssertFalse(second.hasMore)

        // A different chat has no media.
        let chats = try await store.chatSummaries(scope: .talk)
        let alice = try XCTUnwrap(chats.first { $0.mid == "uALICE" })
        let none = try await store.mediaMessages(scope: .talk, filter: .all, chatID: alice.id,
                                                 offset: 0, limit: 100)
        XCTAssertTrue(none.items.isEmpty)
    }

    func testMessageKindFollowsLineContentTypeEnum() {
        XCTAssertEqual(LINEMessageKind(contentType: 0), .text)
        XCTAssertEqual(LINEMessageKind(contentType: 1), .image)
        XCTAssertEqual(LINEMessageKind(contentType: 2), .video)
        XCTAssertEqual(LINEMessageKind(contentType: 3), .audio)
        XCTAssertEqual(LINEMessageKind(contentType: 4), .html)
        XCTAssertEqual(LINEMessageKind(contentType: 5), .flex)
        XCTAssertEqual(LINEMessageKind(contentType: 6), .call)
        XCTAssertEqual(LINEMessageKind(contentType: 7), .sticker)
        XCTAssertEqual(LINEMessageKind(contentType: 12), .link)
        XCTAssertEqual(LINEMessageKind(contentType: 13), .contact)
        XCTAssertEqual(LINEMessageKind(contentType: 14), .file)
        XCTAssertEqual(LINEMessageKind(contentType: 15), .location)
        XCTAssertEqual(LINEMessageKind(contentType: 16), .album)
        XCTAssertEqual(LINEMessageKind(contentType: 17), .rich)
        XCTAssertEqual(LINEMessageKind(contentType: 18), .chatEvent)
        XCTAssertEqual(LINEMessageKind(contentType: 22), .flex)
        XCTAssertEqual(LINEMessageKind(contentType: 96), .image)
        XCTAssertEqual(LINEMessageKind(contentType: 100), .location)
        XCTAssertEqual(LINEMessageKind(contentType: 107), .preview)
        XCTAssertEqual(LINEMessageKind(contentType: 111), .aggregate)
        XCTAssertEqual(LINEMessageKind(contentType: 112), .image)
        XCTAssertEqual(LINEMessageKind(contentType: 999), .other(999))
        // Call history and chat events are centered notices.
        XCTAssertTrue(LINEMessageKind(contentType: 6).isSystemNotice)
        XCTAssertTrue(LINEMessageKind(contentType: 18).isSystemNotice)
        XCTAssertFalse(LINEMessageKind(contentType: 16).isSystemNotice)
        XCTAssertFalse(LINEMessageKind(contentType: 14).isSystemNotice)
    }

    func testMetadataBodiesUseLineProtocolKeys() {
        let flex = ["ALT_TEXT": "こんにちは", "FLEX_VER": "3", "EFFECT_TAG": "celebration"]
        XCTAssertEqual(LINEMetadata.body(kind: .flex, text: nil, metadata: flex), "こんにちは")
        XCTAssertTrue(LINEMetadata.lines(kind: .flex, metadata: flex).contains("Flexバージョン: 3"))
        XCTAssertTrue(LINEMetadata.lines(kind: .flex, metadata: flex).contains("エフェクト: celebration"))

        let location = ["LATITUDE": "35.681236", "LONGITUDE": "139.767125", "address": "東京都千代田区"]
        XCTAssertEqual(LINEMetadata.body(kind: .location, text: nil, metadata: location), "[位置情報] 東京都千代田区")
        XCTAssertTrue(LINEMetadata.lines(kind: .location, metadata: location).contains("緯度経度: 35.681236, 139.767125"))

        let link = ["title": "LINE公式", "linkUri": "https://line.me/"]
        XCTAssertEqual(LINEMetadata.body(kind: .link, text: nil, metadata: link), "[リンク] LINE公式")
        XCTAssertTrue(LINEMetadata.lines(kind: .link, metadata: link).contains("リンク: https://line.me/"))

        let contact = ["displayName": "アリス", "mid": "uALICE"]
        XCTAssertEqual(LINEMetadata.body(kind: .contact, text: nil, metadata: contact), "[連絡先] アリス")
        XCTAssertTrue(LINEMetadata.lines(kind: .contact, metadata: contact).contains("MID: uALICE"))
    }

    func testMetadataDecoderHandlesNestedArchivedValues() throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: [
            "MENTION": [["M": "uALICE", "S": "0", "E": "6"]],
            "EDITED": "true"
        ] as [String: Any], requiringSecureCoding: false)
        let decoded = LINEMetadata.decode(archived)
        XCTAssertTrue(decoded["MENTION"]?.contains("M=uALICE") == true, decoded["MENTION"] ?? "nil")
        XCTAssertTrue(LINEMetadata.lines(kind: .text, metadata: decoded).contains("メンションを含みます"))
        XCTAssertTrue(LINEMetadata.lines(kind: .text, metadata: decoded).contains("編集済み"))
    }

    func testChatTypeUsesZTYPEAndMIDFallback() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        try withDatabase(payload.line) { database in
            try execute(database, """
            INSERT INTO ZCHAT VALUES (5, 'rROOM', 1, 0, '', 700000050),
                                      (6, 'cMIDFALLBACK', 9, 0, '', 700000060),
                                      (7, 'rMIDFALLBACK', 9, 0, '', 700000070);
            INSERT INTO ZMESSAGE VALUES (30, 5, 1700000000000, 'room', 0, 'm30', NULL, NULL),
                                        (31, 6, 1700000001000, 'group', 0, 'm31', NULL, NULL),
                                        (32, 7, 1700000002000, 'room2', 0, 'm32', NULL, NULL);
            """)
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let byID = Dictionary(uniqueKeysWithValues: try await store.chatSummaries(scope: .talk).map { ($0.id, $0) })
        XCTAssertEqual(byID[5]?.kind, .room)
        XCTAssertEqual(byID[6]?.kind, .group)
        XCTAssertEqual(byID[7]?.kind, .room)
    }

    func testGroupNameFallsBackToZGroupInsideLineDatabase() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        try withDatabase(payload.line) { database in
            try execute(database, "INSERT INTO ZGROUP VALUES (1, 'cNAMED', 'ZGROUPの名前');")
        }
        try withDatabase(payload.unified) { database in
            try execute(database, "INSERT INTO ZUNIFIEDGROUP (Z_PK, ZID, ZNAME, ZMEMBERSCOUNT) VALUES (1, 'cNAMED', 'UnifiedGroupの名前', 5);")
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        XCTAssertEqual(chats.first { $0.mid == "cNAMED" }?.name, "ZGROUPの名前")
    }

    func testMediaStoreReadsDirectAppContainerAttachments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("app", isDirectory: true)
        let attachments = appRoot.appendingPathComponent(
            "Library/Application Support/PrivateStore/P_\(accountMID)/Message Attachments/cCHAT", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        try image.write(to: attachments.appendingPathComponent("111.jpg"))
        let pdf = Data("%PDF-1.4".utf8)
        try pdf.write(to: attachments.appendingPathComponent("222_report.pdf"))
        let store = LINEMediaStore(access: FileAccessManager(), accountMID: accountMID,
                                   containerPath: nil, attachmentContainerPath: appRoot.path)
        let hasImage = await store.hasImage(chatMID: "cCHAT", messageID: "111")
        XCTAssertTrue(hasImage)
        let imageData = await store.image(chatMID: "cCHAT", messageID: "111")
        XCTAssertEqual(imageData, image)
        let name = await store.attachmentName(chatMID: "cCHAT", messageID: "222", kind: .file)
        XCTAssertEqual(name, "report.pdf")
        let url = await store.attachmentFile(chatMID: "cCHAT", messageID: "222", kind: .file)
        let fileURL = try XCTUnwrap(url)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: fileURL), pdf)
    }

    func testMediaStoreAvailabilitySeparatesFullThumbnailAndMissing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("app", isDirectory: true)
        let attachments = appRoot.appendingPathComponent(
            "Library/Application Support/PrivateStore/P_\(accountMID)/Message Attachments/cCHAT", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: attachments.appendingPathComponent("111.jpg"))
        let thumbnails = root.appendingPathComponent(
            "Library/Application Support/PrivateStore/P_\(accountMID)/Message Thumbnails/cCHAT", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: thumbnails.appendingPathComponent("111.thumb"))
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: thumbnails.appendingPathComponent("333.thumb"))

        let store = LINEMediaStore(access: FileAccessManager(), accountMID: accountMID,
                                   containerPath: root.path, attachmentContainerPath: appRoot.path)
        let both = LINEMediaKey(chatMID: "cCHAT", messageID: "111")
        let thumbnailOnly = LINEMediaKey(chatMID: "cCHAT", messageID: "333")
        let missing = LINEMediaKey(chatMID: "cCHAT", messageID: "444")
        let states = await store.imageAvailability(keys: [both, thumbnailOnly, missing])
        XCTAssertEqual(states[both], .full)
        XCTAssertEqual(states[thumbnailOnly], .thumbnailOnly)
        XCTAssertEqual(states[missing], .unavailable)

        // Without an attachment container the original is unverified, so a
        // thumbnail-only row must stay visible without a "no original" badge.
        let unverified = LINEMediaStore(access: FileAccessManager(), accountMID: accountMID,
                                        containerPath: root.path, attachmentContainerPath: nil)
        let unknown = await unverified.imageAvailability(keys: [thumbnailOnly])
        XCTAssertEqual(unknown[thumbnailOnly], .unknown)
    }

    func testMediaStoreReadsDeviceThumbnailsAndReportsMissingImages() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileAccessManager()
        let thumbnails = root.appendingPathComponent(
            "Library/Application Support/PrivateStore/P_\(accountMID)/Message Thumbnails/cCHAT", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        let thumbnail = Data([0xff, 0xd8, 0xff, 0xd9])
        try thumbnail.write(to: thumbnails.appendingPathComponent("333.thumb"))
        let store = LINEMediaStore(access: manager, accountMID: accountMID,
                                   containerPath: root.path, attachmentContainerPath: nil)
        let hasThumbnail = await store.hasImage(chatMID: "cCHAT", messageID: "333")
        let missing = await store.hasImage(chatMID: "cCHAT", messageID: "444")
        XCTAssertTrue(hasThumbnail)
        XCTAssertFalse(missing)
        let data = await store.thumbnail(chatMID: "cCHAT", messageID: "333")
        XCTAssertEqual(data, thumbnail)
        // No container means no device media to show.
        let empty = LINEMediaStore(access: manager, accountMID: accountMID,
                                   containerPath: nil, attachmentContainerPath: nil)
        let unavailable = await empty.hasImage(chatMID: "cCHAT", messageID: "333")
        XCTAssertFalse(unavailable)
    }

    func testMediaMessageKindDistinguishesImagesFromVideos() {
        XCTAssertTrue(LINEMessageKind.image.isImage)
        XCTAssertTrue(LINEMessageKind.extImage.isImage)
        XCTAssertFalse(LINEMessageKind.video.isImage)
        XCTAssertFalse(LINEMessageKind.sticker.isImage)
        XCTAssertFalse(LINEMessageKind.file.isImage)
    }

    func testReplyMetadataResolvesOriginalMessagePreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        let reply = NSKeyedArchiver.archivedData(withRootObject: ["replyOriginalMessageId": "m12"])
        try withDatabase(payload.line) { database in
            try execute(database, "INSERT INTO ZMESSAGE VALUES (30, 2, 1700000007000, '返信です', 0, 'm30', NULL, ?);", reply)
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        let chat = try XCTUnwrap(chats.first { $0.mid == "uALICE" })
        let page = try await store.messagePage(chatID: chat.id, offset: 0, scope: .talk)
        let replied = try XCTUnwrap(page.messages.first { $0.messageMID == "m30" })
        XCTAssertEqual(replied.replyToID, "m12")
        XCTAssertEqual(replied.replyTo?.messageID, "m12")
        XCTAssertEqual(replied.replyTo?.senderName, "アリス")
        XCTAssertEqual(replied.replyTo?.body, "確認します")
    }

    func testPredefinedReactionTypesAreRendered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try populateTalkDatabase(line: payload.line)
        try withDatabase(payload.messageExt) { database in
            try execute(database, """
            INSERT INTO ZMESSAGEREACTION VALUES (1, 'm12', 'uALICE', 3, ''),
                                                 (2, 'm12', 'uBOB', 4, '');
            """)
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        let chat = try XCTUnwrap(chats.first { $0.mid == "uALICE" })
        let page = try await store.messagePage(chatID: chat.id, offset: 0, scope: .talk)
        let reactions = try XCTUnwrap(page.messages.last?.reactions)
        XCTAssertEqual(Set(reactions.map(\.emoji)), ["❤️", "😂"])
        XCTAssertTrue(reactions.allSatisfy { !$0.isMine })
    }

    func testOpenChatMessagesResolveSendersAndOwnership() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: true, withSidecars: false)
        try populateOpenChatDatabase(square: payload.square)
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .openChat)
        XCTAssertEqual(chats.map(\.name), ["創英祭2024"])
        let chat = try XCTUnwrap(chats.first)
        let page = try await store.messagePage(chatID: chat.id, offset: 0, scope: .openChat)
        XCTAssertEqual(page.messages.map(\.senderName), ["運営まとめ", "私自身", "運営まとめ"])
        XCTAssertEqual(page.messages.map(\.isMine), [false, true, false])
    }

    func testOpenChatMirrorIsExcludedFromTalkAndRemainsReadableInOpenChat() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: true, withSidecars: false)
        try populateTalkDatabase(line: payload.line, unified: payload.unified, messageExt: payload.messageExt)
        try populateOpenChatDatabase(square: payload.square)
        // LINE mirrors an OpenChat room into Line.sqlite as a multi-person
        // talk. Its messages remain in LineSquare.sqlite.
        try withDatabase(payload.line) { database in
            try execute(database, """
            INSERT INTO ZCHAT VALUES (9, 'cOPEN1', 1, 3, 'ミラー', 700000060),
                                      (10, 'cUNKNOWN', 1, 0, '', 700000070);
            """)
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let talk = try await store.chatSummaries(scope: .talk)
        XCTAssertFalse(talk.contains { $0.mid == "cOPEN1" })
        XCTAssertFalse(talk.contains { $0.mid == "cUNKNOWN" })
        let open = try await store.chatSummaries(scope: .openChat)
        let chat = try XCTUnwrap(open.first { $0.mid == "cOPEN1" })
        XCTAssertEqual(chat.name, "創英祭2024")
        let page = try await store.messagePage(chatID: chat.id, offset: 0, scope: .openChat)
        XCTAssertEqual(page.messages.map(\.text), ["告知です", "了解", "再掲"])
    }

    func testPagingLoadsOlderMessagesInAscendingOrder() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try makeMessagesDirectory(directory: root.appendingPathComponent("Data", isDirectory: true),
                                                includeOpenChat: false, withSidecars: false)
        try withDatabase(payload.line) { database in
            try execute(database, """
            INSERT INTO ZCHAT VALUES (1, 'uALICE', 0, 0, '', 700000000);
            INSERT INTO ZUSER VALUES (2, 'uALICE', 'アリス');
            """)
            var values = ""
            for index in 0..<LINEDataStore.pageSize + 37 {
                values += values.isEmpty ? "" : ", "
                values += "(\(index), 1, \(1_700_000_000_000 + Int64(index * 1000)), 'メッセージ\(index)', 0, 'id\(index)', 2, NULL)"
            }
            try execute(database, "INSERT INTO ZMESSAGE VALUES \(values);")
        }
        let store = LINEDataStore(directory: payload.messages, accountMID: accountMID)
        let chats = try await store.chatSummaries(scope: .talk)
        let chat = try XCTUnwrap(chats.first { $0.mid == "uALICE" })
        XCTAssertEqual(chat.messageCount, LINEDataStore.pageSize + 37)
        let first = try await store.messagePage(chatID: chat.id, offset: 0, scope: .talk)
        XCTAssertTrue(first.hasOlder)
        XCTAssertEqual(first.messages.first?.text, "メッセージ37")
        XCTAssertEqual(first.messages.last?.text, "メッセージ\(LINEDataStore.pageSize + 36)")
        let second = try await store.messagePage(chatID: chat.id, offset: LINEDataStore.pageSize, scope: .talk)
        XCTAssertFalse(second.hasOlder)
        XCTAssertEqual(second.messages.first?.text, "メッセージ0")
        XCTAssertEqual(second.messages.last?.text, "メッセージ36")
        do {
            _ = try await store.messagePage(chatID: chat.id, offset: -1, scope: .talk)
            XCTFail("Negative offset accepted")
        } catch {}
    }

    // MARK: Fixtures

    private struct MessagesFixture {
        let messages: URL
        let line: URL
        let unified: URL
        let messageExt: URL
        let square: URL
    }

    private func makeMessagesDirectory(directory: URL, includeOpenChat: Bool, withSidecars: Bool) throws -> MessagesFixture {
        let messages = directory.appendingPathComponent("Library/Application Support/PrivateStore/P_\(accountMID)/Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let line = messages.appendingPathComponent("Line.sqlite")
        try withDatabase(line) { database in
            try execute(database, """
            CREATE TABLE ZCHAT (Z_PK INTEGER PRIMARY KEY, ZMID VARCHAR, ZTYPE INTEGER, ZUNREAD INTEGER, ZLASTMESSAGE VARCHAR, ZLASTUPDATED TIMESTAMP);
            CREATE TABLE ZUSER (Z_PK INTEGER PRIMARY KEY, ZMID VARCHAR, ZNAME VARCHAR);
            CREATE TABLE ZGROUP (Z_PK INTEGER PRIMARY KEY, ZID VARCHAR, ZNAME VARCHAR);
            CREATE TABLE Z_1MEMBERS (Z_1CHATS INTEGER, Z_12MEMBERS INTEGER, PRIMARY KEY (Z_1CHATS, Z_12MEMBERS));
            CREATE TABLE ZMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHAT INTEGER, ZTIMESTAMP INTEGER, ZTEXT VARCHAR, ZCONTENTTYPE INTEGER, ZID VARCHAR, ZSENDER INTEGER, ZCONTENTMETADATA BLOB);
            """)
        }
        let unified = messages.appendingPathComponent("UnifiedGroup.sqlite")
        try withDatabase(unified) { database in
            try execute(database, """
            CREATE TABLE ZUNIFIEDGROUP (Z_PK INTEGER PRIMARY KEY, ZID VARCHAR, ZNAME VARCHAR, ZMEMBERSCOUNT INTEGER);
            """)
        }
        let messageExt = messages.appendingPathComponent("MessageExt.sqlite")
        try withDatabase(messageExt) { database in
            try execute(database, """
            CREATE TABLE ZMESSAGEREACTION (Z_PK INTEGER PRIMARY KEY, ZMESSAGEID VARCHAR, ZREACTORMID VARCHAR, ZREACTIONTYPE INTEGER, ZCUSTOMREACTION VARCHAR);
            """)
        }
        // Real exports carry WAL sidecars; queries never open these fixtures.
        if withSidecars {
            for role in ["Line", "UnifiedGroup", "MessageExt"] {
                try Data("WAL".utf8).write(to: messages.appendingPathComponent("\(role).sqlite-wal"))
            }
        }
        var square: URL?
        if includeOpenChat {
            let url = messages.appendingPathComponent("LineSquare.sqlite")
            try withDatabase(url) { database in
                try execute(database, """
                CREATE TABLE ZCHAT (Z_PK INTEGER PRIMARY KEY, ZMID VARCHAR, ZNAME VARCHAR, ZUNREAD INTEGER, ZLASTMESSAGE VARCHAR, ZLASTUPDATED TIMESTAMP, ZMEMBERCOUNT INTEGER, ZME INTEGER, ZSQUARE INTEGER);
                CREATE TABLE ZSQUAREMEMBER (Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME VARCHAR, ZMID VARCHAR);
                CREATE TABLE ZMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHAT INTEGER, ZTIMESTAMP INTEGER, ZTEXT VARCHAR, ZCONTENTTYPE INTEGER, ZID VARCHAR, ZSENDER INTEGER, ZCONTENTMETADATA BLOB);
                CREATE TABLE ZMESSAGEREACTION (Z_PK INTEGER PRIMARY KEY, ZMESSAGEID VARCHAR, ZREACTORMID VARCHAR, ZREACTIONTYPE INTEGER, ZCUSTOMREACTION VARCHAR);
                """)
            }
            if withSidecars {
                try Data("WAL".utf8).write(to: messages.appendingPathComponent("LineSquare.sqlite-wal"))
            }
            square = url
        }
        return MessagesFixture(messages: messages, line: line, unified: unified, messageExt: messageExt,
                               square: square ?? messages.appendingPathComponent("LineSquare.sqlite"))
    }

    // Mirrors the rows LINEDataStore reads from the real Core Data schema.
    private func populateTalkDatabase(line: URL, unified: URL? = nil, messageExt: URL? = nil) throws {
        let sticker = NSKeyedArchiver.archivedData(withRootObject: ["STKPKGID": "23812158", "STKID": "605920488"])
        let file = NSKeyedArchiver.archivedData(withRootObject: ["FILE_NAME": "貸家ちらし.pages", "FILE_SIZE": "109897"])
        let unsent = NSKeyedArchiver.archivedData(withRootObject: ["systemMessageTypeName": "ChatMessageUnsent"])
        try withDatabase(line) { database in
            try execute(database, """
            INSERT INTO ZCHAT VALUES (1, '\(accountMID)', 100, 0, '自分へのメモ', 700000010),
                                      (2, 'uALICE', 0, 2, '確認します', 700000020),
                                      (3, 'cGROUP', 2, 0, 'グループ', 700000030),
                                      (4, 'cNAMED', 2, 0, 'OK', 700000040);
            INSERT INTO ZUSER VALUES (2, 'uALICE', 'アリス'), (3, 'uBOB', 'ボブ');
            INSERT INTO Z_1MEMBERS VALUES (3, 2), (3, 3);
            INSERT INTO ZMESSAGE VALUES (10, 2, 1700000000000, 'こんにちは', 0, 'm10', 2, NULL),
                                       (11, 2, 1700000001000, 'こちらこそ', 0, 'm11', NULL, NULL),
                                       (12, 2, 1700000002000, '確認します', 0, 'm12', 2, NULL),
                                       (20, 4, 1700000003000, '', 7, 'm20', 2, ?),
                                       (21, 4, 1700000004000, '', 14, 'm21', 2, ?),
                                       (22, 4, 1700000005000, '了解しました', 0, 'm22', NULL, NULL),
                                       (23, 4, 1700000006000, 'アリスがメッセージの送信を取り消しました', 0, 'm23', 2, ?);
            """, sticker, file, unsent)
        }
        if let unified {
            try withDatabase(unified) { database in
                try execute(database, "INSERT INTO ZUNIFIEDGROUP VALUES (1, 'cNAMED', '開拓者グループ', 5);")
            }
        }
        if let messageExt {
            try withDatabase(messageExt) { database in
                try execute(database, """
                INSERT INTO ZMESSAGEREACTION VALUES (1, 'm12', 'uALICE', 2, '👍'), (2, 'm12', '\(accountMID)', 2, '👍');
                """)
            }
        }
    }

    private func populateOpenChatDatabase(square: URL) throws {
        try withDatabase(square) { database in
            try execute(database, """
            INSERT INTO ZCHAT VALUES (7, 'cOPEN1', '創英祭2024', 0, '運営です', 700000050, 93, 41, NULL);
            INSERT INTO ZSQUAREMEMBER VALUES (41, '私自身', 'uME1'), (55, '運営まとめ', 'uOP1');
            INSERT INTO ZMESSAGE VALUES (1, 7, 1700000010000, '告知です', 0, 'om1', 55, NULL),
                                       (2, 7, 1700000011000, '了解', 0, 'om2', 41, NULL),
                                       (3, 7, 1700000012000, '再掲', 0, 'om3', 55, NULL);
            """)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LINEDataViewerTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func withDatabase(_ url: URL, operation: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open(url.path, &connection)
        defer { if let connection { sqlite3_close(connection) } }
        XCTAssertEqual(result, SQLITE_OK)
        try operation(XCTUnwrap(connection))
    }

    // sqlite3_prepare_v2 only compiles the first statement; iterate the tail
    // so multi-statement fixtures behave like sqlite3_exec (which cannot bind).
    // The tail pointer references the input buffer, so the C string must stay
    // alive inside withUnsafeBufferPointer while it is read back.
    private func execute(_ database: OpaquePointer, _ sql: String, _ blobs: Data...) throws {
        var remaining = sql
        var blobIndex = 0
        while !remaining.isEmpty {
            let cString = Array(remaining.utf8CString)
            let outcome = cString.withUnsafeBufferPointer { buffer -> Result<String, RunnerError> in
                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(database, buffer.baseAddress, Int32(cString.count - 1), &statement, &tail) == SQLITE_OK,
                      let statement else {
                    return .failure(RunnerError(String(cString: sqlite3_errmsg(database))))
                }
                defer { sqlite3_finalize(statement) }
                let parameterCount = Int(sqlite3_bind_parameter_count(statement))
                guard blobIndex + parameterCount <= blobs.count else {
                    return .failure(RunnerError("fixtureのBLOB数が不足しています。"))
                }
                for parameter in 1...max(parameterCount, 1) where parameter <= parameterCount {
                    let blob = blobs[blobIndex + parameter - 1]
                    _ = blob.withUnsafeBytes { raw in
                        sqlite3_bind_blob(statement, Int32(parameter), raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
                    }
                }
                blobIndex += parameterCount
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    return .failure(RunnerError(String(cString: sqlite3_errmsg(database))))
                }
                return .success(tail.map { String(cString: $0) } ?? "")
            }
            switch outcome {
            case .failure(let error): throw error
            case .success(let next):
                guard next != remaining else { throw RunnerError("fixtureのSQLが進行しません。") }
                remaining = next
            }
        }
        guard blobIndex == blobs.count else { throw RunnerError("fixtureのBLOB数が合いません。") }
    }

    private func deflate(_ data: Data) throws -> Data {
        // One-shot raw DEFLATE; the streaming decode path in StoredZIPReader
        // is exercised with chunked input by this compressed payload.
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { outRaw -> Int in
            data.withUnsafeBytes { raw -> Int in
                compression_encode_buffer(outRaw.bindMemory(to: UInt8.self).baseAddress!, outRaw.count,
                                           raw.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw RunnerError("テスト用のDEFLATE圧縮に失敗しました。") }
        return output.prefix(written)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        StoredZIPReader.update(.max, with: data) ^ .max
    }

    private func zipWithEntry(name: String, data: Data) throws -> Data {
        let nameData = Data(name.utf8)
        var zip = Data()
        zip.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
        zip.zip16(20); zip.zip16(0); zip.zip16(0)
        zip.zip16(0); zip.zip16(0x0021)
        zip.zip32(Self.crc32(data)); zip.zip32(UInt32(data.count)); zip.zip32(UInt32(data.count))
        zip.zip16(UInt16(nameData.count)); zip.zip16(0); zip.append(nameData); zip.append(data)
        zip.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
        zip.zip16(0x0314); zip.zip16(20); zip.zip16(0); zip.zip16(0)
        zip.zip16(0); zip.zip16(0x0021)
        zip.zip32(Self.crc32(data)); zip.zip32(UInt32(data.count)); zip.zip32(UInt32(data.count))
        zip.zip16(UInt16(nameData.count)); zip.zip16(0); zip.zip16(0); zip.zip16(0); zip.zip16(0)
        zip.zip32(0o100600 << 16); zip.zip32(0); zip.append(nameData)
        let centralSize = zip.count - 30 - nameData.count - data.count
        zip.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        zip.zip16(0); zip.zip16(0); zip.zip16(1); zip.zip16(1)
        zip.zip32(UInt32(centralSize)); zip.zip32(UInt32(30 + nameData.count + data.count)); zip.zip16(0)
        return zip
    }
}

private extension Data {
    mutating func zip16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func zip32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
