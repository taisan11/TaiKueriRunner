import SwiftUI
import UIKit

// Read-only gallery for the images, files and stickers in the LINE databases.
// Nothing is copied until a row is opened; files are read directly from the
// shared container.
struct LINEMediaGalleryView: View {
    let store: LINEDataStore
    let mediaStore: LINEMediaStore?
    let scope: LINEScope
    var chat: LINEChatSummary?
    var knownChatNames: [Int64: String] = [:]

    @State private var filter: LINEMediaFilter = .all
    @AppStorage("lineMediaHidesMissingImages") private var hideMissingImages = true
    @State private var items: [LINEMediaMessage] = []
    @State private var availability: [LINEMediaKey: LINEMediaAvailability] = [:]
    @State private var loadedChatNames: [Int64: String] = [:]
    @State private var didLoadChatNames = false
    @State private var nextOffset = 0
    @State private var hasMore = false
    @State private var loading = true
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var detail: LINEMediaMessage?
    @State private var loadToken = UUID()

    private let pageSize = 100

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    ContentUnavailableView {
                        Label("メディアを読み込めません", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("再試行", systemImage: "arrow.clockwise") { reload() }
                    }
                }
            } else if loading, items.isEmpty {
                Section {
                    HStack { Spacer(); ProgressView("読み込み中…"); Spacer() }.padding()
                }
            } else if items.isEmpty && !hasMore {
                Section {
                    ContentUnavailableView(hideMissingImages && (filter == .all || filter == .images)
                                           ? L("表示できるメディアはありません")
                                           : (filter == .all ? L("メディアはありません") : L("この種類のメディアはありません")),
                                           systemImage: "photo.on.rectangle.angled",
                                           description: hideMissingImages && (filter == .all || filter == .images)
                                           ? Text(L("サムネイルまたは元ファイルがある画像を表示しています。元ファイルがない画像にはバッジが付きます。"))
                                           : nil)
                }
            } else {
                if items.isEmpty {
                    Section {
                        Text("この範囲に表示できるメディアはありません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            Button { detail = item } label: {
                                LINEMediaGalleryRow(item: item,
                                                    chatTitle: title(for: item),
                                                    mediaStore: mediaStore,
                                                    showsChat: chat == nil,
                                                    availability: availability(for: item))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    if loadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 4)
                    } else if hasMore {
                        Button("さらに読み込む") { loadMore() }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(chat == nil ? L("メディア一覧") : L("メディア"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("表示") {
                        Toggle("サムネイルも元ファイルもない画像を隠す", isOn: $hideMissingImages)
                        Button("再読み込み", systemImage: "arrow.clockwise") { reload() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("メディア一覧の表示")
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                Picker("種類", selection: $filter) {
                    ForEach(LINEMediaFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                Divider()
            }
            .background(.bar)
        }
        .onChange(of: filter) { _, _ in reload() }
        .onChange(of: hideMissingImages) { _, _ in reload() }
        .task { if items.isEmpty, errorMessage == nil { reload() } }
        .sheet(item: $detail) { item in
            LINEMediaDetailView(item: item, mediaStore: mediaStore, chatTitle: title(for: item),
                                availability: availability(for: item))
        }
    }

    private func availability(for item: LINEMediaMessage) -> LINEMediaAvailability? {
        guard item.message.kind.isImage, let messageID = item.message.messageMID else { return nil }
        return availability[LINEMediaKey(chatMID: item.chatMID, messageID: messageID)]
    }

    private func title(for item: LINEMediaMessage) -> String {
        if let chat { return chat.name }
        return knownChatNames[item.chatID]
            ?? loadedChatNames[item.chatID]
            ?? item.chatMID
    }

    private func reload() {
        let token = UUID()
        loadToken = token
        let currentFilter = filter
        items = []
        availability = [:]
        nextOffset = 0
        hasMore = false
        loading = true
        errorMessage = nil
        Task {
            do {
                if chat == nil, knownChatNames.isEmpty, !didLoadChatNames {
                    let chats = try await store.chatSummaries(scope: scope)
                    try Task.checkCancellation()
                    guard loadToken == token else { return }
                    loadedChatNames = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.name) })
                    didLoadChatNames = true
                }
                let page = try await store.mediaMessages(scope: scope, filter: currentFilter,
                                                         chatID: chat?.id, offset: 0, limit: pageSize)
                try Task.checkCancellation()
                let visible = await visibleMedia(page.items, token: token)
                try Task.checkCancellation()
                guard loadToken == token else { return }
                items = visible.items
                availability = visible.availability
                nextOffset = page.items.count
                hasMore = page.hasMore
                loading = false
            } catch is CancellationError {
            } catch {
                guard loadToken == token else { return }
                loading = false
                errorMessage = (error as NSError).localizedDescription
            }
        }
    }

    private func loadMore() {
        guard hasMore, !loading, !loadingMore else { return }
        let token = loadToken
        let currentFilter = filter
        let offset = nextOffset
        loadingMore = true
        Task {
            do {
                let page = try await store.mediaMessages(scope: scope, filter: currentFilter,
                                                         chatID: chat?.id, offset: offset, limit: pageSize)
                try Task.checkCancellation()
                let visible = await visibleMedia(page.items, token: token)
                try Task.checkCancellation()
                guard loadToken == token else { return }
                items += visible.items
                availability.merge(visible.availability) { _, new in new }
                nextOffset = offset + page.items.count
                hasMore = page.hasMore
                loadingMore = false
            } catch is CancellationError {
            } catch {
                guard loadToken == token else { return }
                loadingMore = false
                errorMessage = (error as NSError).localizedDescription
            }
        }
    }

    // Keep every row that has a thumbnail or an original file. A row whose
    // original was confirmed missing stays visible with a badge; only images
    // with neither are hidden when the option is on. Unreadable lookups stay
    // visible and are never badged.
    private func visibleMedia(_ page: [LINEMediaMessage], token: UUID)
        async -> (items: [LINEMediaMessage], availability: [LINEMediaKey: LINEMediaAvailability]) {
        guard let mediaStore else { return (page, [:]) }
        let keys = page.compactMap { item -> LINEMediaKey? in
            guard item.message.kind.isImage, let messageID = item.message.messageMID else { return nil }
            return LINEMediaKey(chatMID: item.chatMID, messageID: messageID)
        }
        let resolved = keys.isEmpty ? [:] : await mediaStore.imageAvailability(keys: keys)
        var items: [LINEMediaMessage] = []
        var states: [LINEMediaKey: LINEMediaAvailability] = [:]
        items.reserveCapacity(page.count)
        for item in page {
            guard loadToken == token, !Task.isCancelled else { return ([], [:]) }
            guard item.message.kind.isImage else {
                items.append(item)
                continue
            }
            guard let messageID = item.message.messageMID else { continue }
            let key = LINEMediaKey(chatMID: item.chatMID, messageID: messageID)
            let state = resolved[key] ?? .unknown
            states[key] = state
            if hideMissingImages, state == .unavailable { continue }
            items.append(item)
        }
        return (items, states)
    }
}

private struct LINEMediaGalleryRow: View {
    let item: LINEMediaMessage
    let chatTitle: String
    let mediaStore: LINEMediaStore?
    let showsChat: Bool
    let availability: LINEMediaAvailability?

    private var message: LINEMessage { item.message }

    private var showsMissingOriginalBadge: Bool { availability == .thumbnailOnly }

    private var primaryTitle: String {
        if showsChat { return chatTitle }
        return message.senderName ?? (message.isMine ? L("自分") : L("（送信者不明）"))
    }

    private var detailLine: String {
        var parts: [String] = [message.kind.title]
        if showsChat, let sender = message.senderName ?? (message.isMine ? L("自分") : nil) {
            parts.append(sender)
        }
        if let fileName = message.fileName {
            parts.append(fileName)
        } else if let text = message.text, !text.isEmpty {
            parts.append(text)
        } else {
            parts.append(message.body)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            LINEMediaThumbnail(message: item.message, chatMID: item.chatMID, mediaStore: mediaStore,
                               showsMissingOriginalBadge: showsMissingOriginalBadge)
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryTitle).font(.subheadline).lineLimit(1)
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
                if showsMissingOriginalBadge {
                    Label("元ファイルなし", systemImage: "photo.badge.exclamationmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct LINEMediaThumbnail: View {
    let message: LINEMessage
    let chatMID: String
    let mediaStore: LINEMediaStore?
    let showsMissingOriginalBadge: Bool
    @State private var image: UIImage?
    @State private var failed = false

    private var isVisual: Bool {
        switch message.kind {
        case .image, .video, .sticker, .extImage: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed || !isVisual {
                Image(systemName: message.kind.symbol).font(.title3).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if message.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            if showsMissingOriginalBadge {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .padding(3)
                    .accessibilityLabel("元ファイルなし")
            }
        }
        .task(id: "\(chatMID)-\(message.id)-\(message.messageMID ?? "")") { await load() }
        .onDisappear { image = nil }
    }

    private func load() async {
        failed = false
        guard isVisual, let mediaStore else {
            failed = true
            return
        }
        let data: Data?
        if message.kind == .sticker {
            data = await mediaStore.sticker(packageID: message.metadata["STKPKGID"],
                                            version: message.metadata["STKVER"],
                                            stickerID: message.metadata["STKID"])
        } else if let messageID = message.messageMID {
            if let thumbnail = await mediaStore.thumbnail(chatMID: chatMID, messageID: messageID) {
                data = thumbnail
            } else {
                // Some messages only have the original attachment. Use it for
                // the row instead of leaving a spinner that never finishes.
                data = await mediaStore.image(chatMID: chatMID, messageID: messageID)
            }
        } else {
            data = nil
        }
        if let data, let loaded = UIImage(data: data) {
            guard !Task.isCancelled else { return }
            // Show LINE's stored thumbnail as-is. Resizing it here would only
            // create another downscaled copy for the 56pt row.
            image = loaded
        } else {
            failed = true
        }
    }
}

private struct LINEMediaDetailView: View {
    let item: LINEMediaMessage
    let mediaStore: LINEMediaStore?
    let chatTitle: String
    let availability: LINEMediaAvailability?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var imageFailed = false
    @State private var preparingShare = false
    @State private var shareFile: LINEMediaShareFile?
    @State private var shareDirectory: URL?
    @State private var errorMessage: String?

    private var message: LINEMessage { item.message }

    private var isVisual: Bool {
        switch message.kind {
        case .image, .video, .sticker, .extImage: true
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if isVisual {
                    Section {
                        Group {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 360)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else if imageFailed {
                                ContentUnavailableView("画像を表示できません", systemImage: "photo.badge.exclamationmark")
                            } else {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                        }
                    } footer: {
                        if availability == .thumbnailOnly {
                            Label("元ファイル（フルサイズ）は端末にありません。サムネイルを表示しています。",
                                  systemImage: "photo.badge.exclamationmark")
                        }
                    }
                }
                Section("メディア") {
                    MediaInfoRow("トーク", chatTitle)
                    MediaInfoRow("送信者", message.senderName ?? (message.isMine ? L("自分") : L("（不明）")))
                    MediaInfoRow("日時", message.date.formatted(date: .abbreviated, time: .shortened))
                    MediaInfoRow("種類", message.kind.title)
                    if let fileName = message.fileName { MediaInfoRow("ファイル名", fileName) }
                    if let size = message.fileSize {
                        MediaInfoRow("サイズ", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if availability == .thumbnailOnly {
                        MediaInfoRow("元ファイル", L("なし（サムネイルのみ）"))
                    }
                }
                if let text = message.text, !text.isEmpty {
                    Section("本文") {
                        Text(text).font(.subheadline).textSelection(.enabled)
                    }
                }
                Section {
                    Button("共有 / 別のアプリで開く", systemImage: "square.and.arrow.up") { prepareShare() }
                        .disabled(preparingShare || mediaStore == nil)
                    if preparingShare { ProgressView("共有用のコピーを準備中…") }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                } footer: {
                    Text("画像はフル解像度がない場合にサムネイルを共有します。ファイル・動画の本体は共有フォルダに含まれないため共有できません。")
                }
            }
            .navigationTitle("メディア詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task { await loadPreview() }
            .sheet(item: $shareFile, onDismiss: cleanupShare) { file in
                FileShareController(url: file.url) { shareFile = nil }
            }
        }
    }

    private func loadPreview() async {
        guard isVisual, let mediaStore else {
            imageFailed = true
            return
        }
        let data: Data?
        switch message.kind {
        case .sticker:
            data = await mediaStore.sticker(packageID: message.metadata["STKPKGID"],
                                            version: message.metadata["STKVER"],
                                            stickerID: message.metadata["STKID"])
        case .image, .extImage:
            guard let messageID = message.messageMID else { data = nil; break }
            data = await mediaStore.image(chatMID: item.chatMID, messageID: messageID)
        case .video:
            guard let messageID = message.messageMID else { data = nil; break }
            data = await mediaStore.thumbnail(chatMID: item.chatMID, messageID: messageID)
        default:
            data = nil
        }
        if let data, let loaded = UIImage(data: data) {
            image = loaded
        } else {
            imageFailed = true
        }
    }

    private func prepareShare() {
        guard !preparingShare, let mediaStore else { return }
        guard let messageID = message.messageMID else {
            errorMessage = L("メッセージIDがないため共有できません。")
            return
        }
        preparingShare = true
        errorMessage = nil
        Task {
            switch message.kind {
            case .video, .file, .audio, .pdf:
                guard let url = await mediaStore.attachmentFile(chatMID: item.chatMID,
                                                                messageID: messageID,
                                                                kind: message.kind) else {
                    errorMessage = L("ファイル本体が見つかりません。jp.naver.lineのアプリコンテナを読み取れるか確認してください。")
                    preparingShare = false
                    return
                }
                shareDirectory = url.deletingLastPathComponent()
                shareFile = LINEMediaShareFile(url: url)
                preparingShare = false
                return
            default:
                break
            }
            let data: Data?
            switch message.kind {
            case .sticker:
                data = await mediaStore.sticker(packageID: message.metadata["STKPKGID"],
                                                version: message.metadata["STKVER"],
                                                stickerID: message.metadata["STKID"])
            case .image, .extImage:
                data = await mediaStore.image(chatMID: item.chatMID, messageID: messageID)
            default:
                data = nil
            }
            guard let data, !data.isEmpty else {
                errorMessage = L("このファイルは共有フォルダまたは添付ZIPで確認できませんでした。")
                preparingShare = false
                return
            }
            let name = await shareName(mediaStore: mediaStore, messageID: messageID)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LINEMediaShare-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                shareDirectory = directory
                shareFile = LINEMediaShareFile(url: url)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                errorMessage = error.localizedDescription
            }
            preparingShare = false
        }
    }

    private func shareName(mediaStore: LINEMediaStore, messageID: String) async -> String {
        let raw: String
        if let fileName = message.fileName {
            raw = fileName
        } else if let attachmentName = await mediaStore.attachmentName(chatMID: item.chatMID,
                                                                       messageID: messageID,
                                                                       kind: message.kind) {
            raw = attachmentName
        } else {
            raw = fallbackName
        }
        var name = URL(fileURLWithPath: raw).lastPathComponent
        let prefix = messageID + "_"
        if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        name = name.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty || name == "." || name == ".." {
            name = fallbackName
        }
        return String(name.prefix(200))
    }

    private var fallbackName: String {
        switch message.kind {
        case .image, .extImage: "LINE-image-\(message.id).jpg"
        case .video: "LINE-video-\(message.id).mp4"
        case .sticker: "LINE-sticker-\(message.id).png"
        case .audio: "LINE-audio-\(message.id)"
        default: "LINE-file-\(message.id)"
        }
    }

    private func cleanupShare() {
        if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
        shareDirectory = nil
    }
}

private struct LINEMediaShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MediaInfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = LKey(label)
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
}
