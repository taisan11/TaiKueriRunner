import SwiftUI
import UIKit

// The staged databases must survive as long as the viewer route is on the
// navigation stack. Pushing a chat also calls onDisappear on the list, so
// deleting there made the chat list fail when the user came back. Cleanup is
// tied to the view being released instead.
private final class LINEDataStagingCleanup: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var access: FileAccessManager?
    private var staged: StagedDocumentPreview?

    func attach(access: FileAccessManager, staged: StagedDocumentPreview) {
        lock.lock()
        self.access = access
        self.staged = staged
        lock.unlock()
    }

    deinit {
        lock.lock()
        let access = access
        let staged = staged
        lock.unlock()
        guard let access, let staged else { return }
        Task { await access.closeDocumentPreview(staged) }
    }
}

// Reads the chat databases directly out of a live App Group container (found
// by the LINE viewer's automatic scan). The container is only ever read;
// queries target private snapshot copies.
struct LINEDataDeviceView: View {
    let group: AppGroupContainer
    @Environment(AppModel.self) private var model
    @StateObject private var cleanup = LINEDataStagingCleanup()
    @State private var summary: LINEArchiveSummary?
    @State private var staged: StagedDocumentPreview?
    @State private var store: LINEDataStore?
    @State private var mediaStore: LINEMediaStore?
    @State private var notFound = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let store, let summary {
                LINEChatList(store: store, summary: summary, mediaStore: mediaStore)
            } else if notFound {
                ContentUnavailableView {
                    Label("LINEのメッセージDBが見つかりません", systemImage: "bubble.left.and.bubble.right.slash")
                } description: {
                    Text("この共有フォルダのPrivateStore/Messages/Line.sqliteを確認できませんでした。LINEを一度起動してから、この画面を開き直してください。")
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("LINEデータを読み取れません", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("再試行", systemImage: "arrow.clockwise") { load() }
                }
            } else {
                ProgressView {
                    VStack(spacing: 6) {
                        Text("LINEデータを準備中…")
                        if let summary {
                            Text("共有フォルダからメッセージDBを一時フォルダへコピーしています（約\(String(describing: ByteCountFormatter.string(fromByteCount: summary.stagingBytes, countStyle: .file)))）")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("共有フォルダを確認しています…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("LINEのトーク")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func load() {
        guard store == nil, staged == nil else { return }
        notFound = false
        errorMessage = nil
        model.run(L("LINEデータの確認")) {
            guard let found = try await model.accessManager.readLINEArchiveSummary(containerPath: group.path) else {
                notFound = true
                return
            }
            self.summary = found
            let staged = try await model.accessManager.stageLINEData(containerPath: group.path, summary: found, includeOpenChat: found.hasOpenChat)
            guard !Task.isCancelled else {
                await model.accessManager.closeDocumentPreview(staged)
                throw CancellationError()
            }
            self.staged = staged
            cleanup.attach(access: model.accessManager, staged: staged)
            var attachmentContainer = lineAppContainerPath
            if attachmentContainer == nil {
                if let snapshot = try? await model.loadApplications() {
                    model.applicationCatalog.adopt(snapshot)
                    attachmentContainer = Self.lineAppContainerPath(in: snapshot.catalog)
                }
            }
            self.mediaStore = LINEMediaStore(access: model.accessManager, accountMID: found.accountMID,
                                            containerPath: group.path,
                                            attachmentContainerPath: attachmentContainer)
            self.store = LINEDataStore(directory: staged.directory, accountMID: found.accountMID)
        }
    }

    private var lineAppContainerPath: String? {
        guard let snapshot = model.applicationCatalog.snapshot else { return nil }
        return Self.lineAppContainerPath(in: snapshot.catalog)
    }

    private static func lineAppContainerPath(in catalog: ParsedApplicationCatalog) -> String? {
        catalog.applications.first {
            $0.kind == .application && $0.bundleID == "jp.naver.line"
        }?.containerPaths.first
    }
}

private struct LINEChatList: View {
    let store: LINEDataStore
    let summary: LINEArchiveSummary
    let mediaStore: LINEMediaStore?
    @State private var scope: LINEScope = .talk
    @State private var chats: [LINEChatSummary]?
    @State private var listError: String?
    @State private var search = ""

    private var visibleChats: [LINEChatSummary] {
        guard let chats else { return [] }
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return chats }
        return chats.filter { chat in
            chat.name.localizedCaseInsensitiveContains(term) ||
            chat.memberNames.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    private var sortedChats: [LINEChatSummary] {
        (search.trimmingCharacters(in: .whitespaces).isEmpty ? (chats ?? []) : visibleChats)
            .sorted {
                ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast)
            }
    }

    private var chatNameMap: [Int64: String] {
        Dictionary(uniqueKeysWithValues: (chats ?? []).map { ($0.id, $0.name) })
    }

    var body: some View {
        List {
            if let listError {
                ContentUnavailableView("トーク一覧を読み込めません", systemImage: "bubble.left.and.bubble.right.slash", description: Text(listError))
            } else if chats == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.padding()
            } else if sortedChats.isEmpty {
                ContentUnavailableView(search.isEmpty ? "トークはありません" : "一致するトークはありません",
                                        systemImage: search.isEmpty ? "bubble.left" : "magnifyingglass")
            } else {
                ForEach(sortedChats) { chat in
                    NavigationLink {
                        LINEChatMessagesView(store: store, chat: chat, scope: scope, mediaStore: mediaStore)
                    } label: {
                        LINEChatRow(chat: chat)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "トーク名・メンバー名で検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LINEMediaGalleryView(store: store, mediaStore: mediaStore, scope: scope,
                                         knownChatNames: chatNameMap)
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .accessibilityLabel("メディア一覧")
            }
        }
        .safeAreaInset(edge: .top) {
            if summary.hasOpenChat {
                Picker("対象", selection: $scope) {
                    ForEach(LINEScope.allCases) { scope in Text(scope.title).tag(scope) }
                }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 6)
            }
        }
        .onChange(of: scope) { _, _ in chats = nil; load() }
        .task { load() }
    }

    private func load() {
        let current = scope
        Task {
            do {
                let result = try await store.chatSummaries(scope: current)
                try Task.checkCancellation()
                if scope == current { withAnimation { chats = result; listError = nil } }
            } catch is CancellationError {
            } catch {
                let message = (error as NSError).localizedDescription
                // A reload caused by returning from a chat must not replace a
                // list that is already on screen with an error.
                if scope == current, !Task.isCancelled, chats == nil { listError = message }
            }
        }
    }
}

private struct LINEChatRow: View {
    let chat: LINEChatSummary

    // Follow the device locale so dates match the selected language/region.
    private static let dateStyle = Date.FormatStyle(date: .numeric, time: .omitted,
                                                    locale: Locale.autoupdatingCurrent)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: chat.kind.symbol)
                .font(.subheadline).foregroundStyle(.tint)
                .frame(width: 22)
            Text(chat.name).font(.headline).lineLimit(1)
            Spacer(minLength: 6)
            Text(chat.lastUpdated.map { $0.formatted(Self.dateStyle) } ?? "—")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LINEChatMessagesView: View {
    let store: LINEDataStore
    let chat: LINEChatSummary
    let scope: LINEScope
    let mediaStore: LINEMediaStore?
    private static let maximumRetainedMessages = 2_000
    @State private var messages: [LINEMessage] = []
    @State private var hasOlder = false
    @State private var loading = true
    @State private var loadingOlder = false
    @State private var messageError: String?
    @State private var search = ""
    @State private var searchResults: [LINEMessage]?
    @State private var searchError: String?
    @State private var detail: LINEMessage?
    @State private var loadedOffset = 0
    @State private var didInitialScroll = false
    @State private var droppedNewest = false

    var body: some View {
        Group {
            if let messageError {
                ContentUnavailableView("メッセージを読み込めません", systemImage: "bubble.left.and.bubble.right.slash", description: Text(messageError))
            } else {
                messageList
            }
        }
        .navigationTitle(chat.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LINEMediaGalleryView(store: store, mediaStore: mediaStore, scope: scope, chat: chat,
                                         knownChatNames: [chat.id: chat.name])
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .accessibilityLabel("このトークのメディア")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "メッセージを検索（2文字以上）")
        .onChange(of: search) { _, term in search(term) }
        .sheet(item: $detail) { message in LINEMessageDetailView(message: message, chat: chat) }
        .task { load(initial: true) }
    }

    private static let dayStyle = Date.FormatStyle(date: .long, time: .omitted,
                                                   locale: Locale.autoupdatingCurrent)

    private var messageList: some View {
        let messageHeaderIDs = dayHeaderIDs(for: messages)
        let searchHeaderIDs = dayHeaderIDs(for: searchResults ?? [])
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if hasOlder {
                        Button {
                            load(initial: false)
                        } label: {
                            HStack(spacing: 8) {
                                if loadingOlder { ProgressView() }
                                Text("過去のメッセージを読み込む").font(.subheadline)
                            }.padding(.vertical, 10)
                        }.disabled(loadingOlder)
                    }
                    if loading, messages.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                    }
                    if let searchResults {
                        if searchResults.isEmpty {
                            Text("一致するメッセージはありません").font(.subheadline)
                                .foregroundStyle(.secondary).padding(.top, 60)
                        } else {
                            Text("検索結果 \(String(describing: searchResults.count.formatted()))件（新しい順に最大\(String(describing: LINEDataStore.maximumSearchResults.formatted()))件）")
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                            ForEach(searchResults) { message in
                                if searchHeaderIDs.contains(message.id) {
                                    dayHeader(for: message.date)
                                }
                                LINEMessageRow(message: message, chat: chat, mediaStore: mediaStore,
                                               showSender: true) { detail = message }
                            }
                        }
                    } else {
                        ForEach(messages) { message in
                            if messageHeaderIDs.contains(message.id) {
                                dayHeader(for: message.date)
                            }
                            LINEMessageRow(message: message, chat: chat, mediaStore: mediaStore,
                                           showSender: !message.isMine) { detail = message }
                                .id(message.id)
                        }
                        if droppedNewest {
                            Button("最新のメッセージに戻る", systemImage: "arrow.down.to.line") {
                                reloadLatest()
                            }
                            .font(.subheadline)
                            .padding(.vertical, 12)
                        }
                        if !loading, messages.isEmpty {
                            Text("メッセージはありません").font(.subheadline)
                                .foregroundStyle(.secondary).padding(.top, 60)
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
            .defaultScrollAnchor(.bottom)
            .task(id: messages.last?.id) {
                guard !didInitialScroll, let id = messages.last?.id else { return }
                didInitialScroll = true
                await Task.yield()
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func dayHeaderIDs(for list: [LINEMessage]) -> Set<Int64> {
        var ids = Set<Int64>()
        var previous: Date?
        for message in list {
            if previous.map({ !Calendar.current.isDate(message.date, inSameDayAs: $0) }) ?? true {
                ids.insert(message.id)
            }
            previous = message.date
        }
        return ids
    }

    private func dayHeader(for date: Date) -> some View {
        Text(date.formatted(Self.dayStyle))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func load(initial: Bool) {
        guard initial || !loadingOlder else { return }
        let offset = initial ? 0 : loadedOffset + LINEDataStore.pageSize
        if !initial { loadingOlder = true } else { loading = true }
        Task {
            do {
                let page = try await store.messagePage(chatID: chat.id, offset: offset, scope: scope)
                try Task.checkCancellation()
                if initial {
                    messages = page.messages
                    droppedNewest = false
                } else {
                    var combined = page.messages + messages
                    if combined.count > Self.maximumRetainedMessages {
                        combined = Array(combined.prefix(Self.maximumRetainedMessages))
                        droppedNewest = true
                    }
                    messages = combined
                }
                hasOlder = page.hasOlder
                loadedOffset = offset
                loading = false
                loadingOlder = false
            } catch is CancellationError {
            } catch {
                let message = (error as NSError).localizedDescription
                loading = false
                loadingOlder = false
                if !Task.isCancelled { messageError = message }
            }
        }
    }

    private func reloadLatest() {
        messages = []
        hasOlder = false
        loadedOffset = 0
        droppedNewest = false
        didInitialScroll = false
        load(initial: true)
    }

    private func search(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = nil
            searchError = nil
            return
        }
        Task {
            do {
                let results = try await store.searchMessages(chatID: chat.id, term: trimmed, scope: scope)
                try Task.checkCancellation()
                if search.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    searchResults = results
                    searchError = nil
                }
            } catch is CancellationError {
            } catch {
                let message = (error as NSError).localizedDescription
                if !Task.isCancelled { searchError = message }
            }
        }
    }
}

struct LINEMessageRow: View {
    let message: LINEMessage
    let chat: LINEChatSummary
    let mediaStore: LINEMediaStore?
    let showSender: Bool
    var openDetail: () -> Void
    @State private var showReadReceipt = false
    @State private var stickerImageLoaded = false
    @State private var attachmentShare: LINEAttachmentShareFile?
    @State private var attachmentShareDirectory: URL?
    @State private var preparingAttachment = false
    @State private var attachmentError: String?

    private var showsReadReceipt: Bool {
        message.isMine && !message.isSystem && chat.kind != .selfChat
    }

    private var readReceiptLabel: String {
        switch chat.kind {
        case .oneToOne: message.readCount > 0 ? L("既読") : L("未読")
        default: message.readCount > 0 ? L("既読 \(String(describing: message.readCount.formatted()))") : L("未読")
        }
    }

    var body: some View {
        if message.isSystem {
            VStack(spacing: 2) {
                Text(message.body)
                ForEach(message.metadataLines, id: \.self) { line in
                    Text(line).font(.caption2)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, 4)
            .contextMenu { Button("詳細を表示", systemImage: "info.circle") { openDetail() } }
        } else {
            HStack(alignment: .bottom, spacing: 4) {
                if message.isMine { Spacer(minLength: 24) }
                if message.isMine {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize()
                }
                if !message.isMine {
                    ZStack {
                        Circle().fill(.quaternary)
                        Text(String(message.senderName?.first ?? "?"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(width: 28, height: 28)
                }
                VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                    if showSender, let name = message.senderName {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    bubble
                    if !message.reactions.isEmpty {
                        reactions
                    }
                    if showsReadReceipt {
                        Button { showReadReceipt = true } label: {
                            HStack(spacing: 4) {
                                Image(systemName: message.readCount > 0 ? "checkmark.circle.fill" : "circle")
                                Text(readReceiptLabel)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(message.readCount > 0 ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(L("既読状況: \(String(describing: readReceiptLabel))"))
                    }
                }
                if !message.isMine {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize()
                    Spacer(minLength: 24)
                }
            }
            .padding(.vertical, 2)
            .contextMenu { Button("詳細を表示", systemImage: "info.circle") { openDetail() } }
            .sheet(isPresented: $showReadReceipt) {
                LINEReadReceiptView(chat: chat, message: message)
            }
            .sheet(item: $attachmentShare, onDismiss: cleanupAttachmentShare) { file in
                FileShareController(url: file.url) { attachmentShare = nil }
            }
        }
    }

    private var showsMedia: Bool {
        switch message.kind {
        case .image, .video, .sticker, .extImage: true
        default: false
        }
    }

    private var showsAttachmentButton: Bool {
        switch message.kind {
        case .video, .file, .audio, .pdf: true
        default: false
        }
    }

    private func openAttachment() {
        guard !preparingAttachment, let mediaStore, let messageID = message.messageMID else { return }
        preparingAttachment = true
        attachmentError = nil
        Task {
            if let url = await mediaStore.attachmentFile(chatMID: chat.mid,
                                                         messageID: messageID,
                                                         kind: message.kind) {
                attachmentShareDirectory = url.deletingLastPathComponent()
                attachmentShare = LINEAttachmentShareFile(url: url)
            } else {
                attachmentError = L("ファイル本体が見つかりません。jp.naver.lineのアプリコンテナを読み取れるか確認してください。")
            }
            preparingAttachment = false
        }
    }

    private func cleanupAttachmentShare() {
        if let directory = attachmentShareDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        attachmentShareDirectory = nil
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyTo {
                replyPreview(reply)
            }
            if message.kind != .text, !showsMedia {
                Label(message.kind.title, systemImage: message.kind.symbol)
                    .font(.caption.bold())
            }
            if showsMedia {
                LINEMessageMediaView(message: message, chatMID: chat.mid, mediaStore: mediaStore) { loaded in
                    if message.kind == .sticker { stickerImageLoaded = loaded }
                }
                if let text = message.text, !text.isEmpty {
                    Text(text).font(.subheadline).textSelection(.enabled)
                }
            } else {
                Text(message.body).font(.subheadline)
                    .textSelection(.enabled)
            }
            if !(message.kind == .sticker && stickerImageLoaded) {
                ForEach(message.metadataLines, id: \.self) { line in
                    Text(line).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if showsAttachmentButton {
                Button {
                    openAttachment()
                } label: {
                    Label(preparingAttachment ? L("準備中…") : L("開く / 共有"), systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(preparingAttachment)
                if let attachmentError {
                    Text(attachmentError).font(.caption2).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, message.kind == .sticker ? 4 : 12)
        .padding(.vertical, message.kind == .sticker ? 4 : 8)
        .background(message.kind == .sticker ? Color.clear
                    : (message.isMine ? Color.accentColor.opacity(0.28) : Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 280, alignment: message.isMine ? .trailing : .leading)
    }

    private func replyPreview(_ reply: LINEReplyPreview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reply.senderName ?? L("返信先"))
                .font(.caption2.bold()).foregroundStyle(.secondary)
            Text(reply.body)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Text("\(reaction.emoji) \(reaction.count.formatted())")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(reaction.isMine ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                in: Capsule())
            }
        }
    }
}

// Loads device thumbnails and sticker PNGs on demand. The stored thumbnail is
// shown as-is instead of generating another downscaled copy. Text is always
// shown even when the shared folder has no media entry, so missing media stays
// readable.
struct LINEMessageMediaView: View {
    let message: LINEMessage
    let chatMID: String
    let mediaStore: LINEMediaStore?
    var onImageLoaded: ((Bool) -> Void)? = nil
    @State private var image: UIImage?
    @State private var fullImage: UIImage?
    @State private var failed = false

    private var isSticker: Bool { message.kind == .sticker }
    private var isImageKind: Bool { message.kind == .image || message.kind == .extImage }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: isSticker ? 120 : 240, maxHeight: isSticker ? 120 : 280)
                    .clipShape(RoundedRectangle(cornerRadius: isSticker ? 0 : 10))
                    .overlay(alignment: .bottomTrailing) {
                        if message.kind == .video {
                            Image(systemName: "play.circle.fill")
                                .font(.title2).foregroundStyle(.white, .black.opacity(0.55))
                                .padding(6)
                        }
                    }
                    .onTapGesture { if isImageKind { loadFull() } }
            } else if !failed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 160, height: 110)
                    .overlay(ProgressView())
            } else {
                Text("[\(message.kind.title)]")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(chatMID)-\(message.id)-\(message.messageMID ?? "")") {
            await loadThumbnail()
        }
        .onDisappear {
            // Lazy rows can stay alive offscreen; release the decoded image.
            image = nil
        }
        .sheet(isPresented: Binding(get: { fullImage != nil },
                                    set: { if !$0 { fullImage = nil } })) {
            if let fullImage { LINEFullImageView(image: fullImage) }
        }
    }

    private func loadThumbnail() async {
        failed = false
        onImageLoaded?(false)
        guard let mediaStore else { failed = true; return }
        let data: Data?
        if isSticker {
            data = await mediaStore.sticker(packageID: message.metadata["STKPKGID"],
                                            version: message.metadata["STKVER"],
                                            stickerID: message.metadata["STKID"])
        } else if let messageID = message.messageMID {
            data = await mediaStore.thumbnail(chatMID: chatMID, messageID: messageID)
        } else {
            data = nil
        }
        if let data, let loaded = UIImage(data: data) {
            guard !Task.isCancelled else { return }
            // The device thumbnail is already small; display it without
            // generating another downscaled copy.
            image = loaded
            onImageLoaded?(true)
        } else {
            failed = true
            onImageLoaded?(false)
        }
    }

    private func loadFull() {
        guard isImageKind, let mediaStore, let messageID = message.messageMID else { return }
        Task {
            let data = await mediaStore.image(chatMID: chatMID, messageID: messageID)
            if let data, let loaded = UIImage(data: data) {
                fullImage = loaded
            } else {
                fullImage = image
            }
        }
    }
}

private struct LINEAttachmentShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct LINEFullImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LINEZoomableImageView(image: image)
                .background(Color.black)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("画像").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}

// UIScrollView provides the pinch/pan behavior people expect from an image
// viewer: the image starts fitted to the screen instead of overflowing at its
// native size, and double-tap toggles a closer view.
private struct LINEZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        scrollView.onLayout = { [weak scrollView, weak coordinator = context.coordinator] in
            guard let scrollView, let imageView = coordinator?.imageView else { return }
            coordinator?.layout(imageView: imageView, in: scrollView)
        }

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            context.coordinator.resetZoom(in: scrollView)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        private var lastBounds: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func layout(imageView: UIImageView, in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0, bounds != lastBounds,
                  let imageSize = imageView.image?.size,
                  imageSize.width > 0, imageSize.height > 0 else { return }
            lastBounds = bounds
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            scrollView.zoomScale = 1
            center(imageView: imageView, in: scrollView)
        }

        func resetZoom(in scrollView: UIScrollView) {
            lastBounds = .zero
            scrollView.setZoomScale(1, animated: false)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            center(imageView: imageView, in: scrollView)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView, let imageView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let target = min(scrollView.maximumZoomScale, max(2, scrollView.minimumZoomScale * 2.5))
            let point = gesture.location(in: imageView)
            let width = scrollView.bounds.width / target
            let height = scrollView.bounds.height / target
            scrollView.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2,
                                       width: width, height: height), animated: true)
        }

        private func center(imageView: UIImageView, in scrollView: UIScrollView) {
            let bounds = scrollView.bounds.size
            let content = imageView.frame.size
            let horizontal = max(0, (bounds.width - content.width) / 2)
            let vertical = max(0, (bounds.height - content.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                                   bottom: vertical, right: horizontal)
        }
    }
}

private final class ZoomScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private struct LINEReadReceiptView: View {
    let chat: LINEChatSummary
    let message: LINEMessage
    @Environment(\.dismiss) private var dismiss

    private var allMembersRead: Bool {
        !chat.memberNames.isEmpty && message.readCount >= chat.memberNames.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("メッセージ") {
                    LabeledValue("日時", message.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledValue("既読数", "\(String(describing: message.readCount.formatted()))人")
                }
                Section("既読した人") {
                    switch chat.kind {
                    case .oneToOne:
                        if message.readCount > 0 {
                            Label(chat.name, systemImage: "checkmark.circle.fill")
                        } else {
                            Text("まだ読まれていません").foregroundStyle(.secondary)
                        }
                    default:
                        if allMembersRead {
                            ForEach(chat.memberNames, id: \.self) { name in
                                Label(name, systemImage: "checkmark.circle.fill")
                            }
                        } else if message.readCount > 0 {
                            Text("既読数は\(String(describing: message.readCount.formatted()))人です。LINEが端末に保存するのは既読数だけで、既読した人の名前は残りません。")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("まだ読まれていません").foregroundStyle(.secondary)
                        }
                    }
                }
                if chat.kind != .oneToOne, !chat.memberNames.isEmpty, !allMembersRead {
                    Section("メンバー") {
                        ForEach(chat.memberNames, id: \.self) { Text($0) }
                    }
                }
                Section {
                    Text("LINEアプリは既読数だけを端末に保存し、誰が読んだかは保存しません。全員既読と分かる場合だけ名前を表示しています。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("既読した人").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct LINEMessageDetailView: View {
    let message: LINEMessage
    let chat: LINEChatSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("メッセージ") {
                    LabeledValue("種類", message.kind.title)
                    LabeledValue("日時", message.date.formatted(date: .complete, time: .standard))
                    if let sender = message.senderName { LabeledValue("送信者", sender) }
                    else if message.isMine { LabeledValue("送信者", L("自分")) }
                    else if message.isSystem { LabeledValue("送信者", L("システム")) }
                    LabeledValue("自分のメッセージ", message.isMine ? L("はい") : L("いいえ"))
                    if let mid = message.messageMID { LabeledValue("メッセージID", mid) }
                }
                if message.isMine, !message.isSystem, chat.kind != .selfChat {
                    Section("既読") {
                        LabeledValue("既読数", "\(String(describing: message.readCount.formatted()))人")
                        if chat.kind == .oneToOne {
                            LabeledValue("相手", chat.name)
                        } else {
                            Text("LINEが端末に保存するのは既読数だけで、既読した人の名前は残りません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let text = message.text, !text.isEmpty {
                    Section("本文") {
                        Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if let reply = message.replyTo {
                    Section("返信先") {
                        if let sender = reply.senderName { LabeledValue("送信者", sender) }
                        LabeledValue("本文", reply.body)
                        LabeledValue("メッセージID", reply.messageID)
                    }
                } else if let replyID = message.replyToID {
                    Section("返信先") {
                        LabeledValue("メッセージID", replyID)
                    }
                }
                if !message.reactions.isEmpty {
                    Section("リアクション") {
                        ForEach(message.reactions) { reaction in
                            LabeledValue(reaction.emoji + " ×\(reaction.count.formatted())",
                                         reaction.reactorNames.joined(separator: "、"))
                        }
                    }
                }
                if !message.metadata.isEmpty {
                    Section("メタデータ（保存されている値）") {
                        ForEach(message.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(value.isEmpty ? L("（空）") : value)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("メッセージ詳細").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

private struct LabeledValue: View {
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
