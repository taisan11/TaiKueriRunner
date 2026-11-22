import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct WallpaperView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("wallpaperActivationAcknowledged") private var acknowledged = 0.0
    @AppStorage("wallpaperShowPhotosAndVideos") private var showPhotosAndVideos = false
    private var library: WallpaperLibraryModel { model.wallpaperLibrary }
    @State private var filter = LibraryFilter.gallery
    @State private var search = ""
    @State private var showImport = false
    @State private var selection: InstalledWallpaper?
    @State private var request: FileWriteRequest?
    @State private var reloadID = UUID()
    @State private var actionError: String?
    @State private var preparing = false
    @State private var generation = UUID()
    @State private var forceReload = false
    @State private var visible = false
    @State private var paused = false
    private let columns = [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 16)]

    private struct RefreshRequest: Equatable {
        let active: Bool
        let revision: Int
        let reloadID: UUID
    }

    private var refreshRequest: RefreshRequest {
        RefreshRequest(active: visible && scenePhase == .active && model.selectedTab == .home &&
                       !model.busy && !showImport && selection == nil && request == nil && !paused,
                        revision: model.fileWriteRevision, reloadID: reloadID)
    }

    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case managed = "追加した壁紙", gallery = "ギャラリー", saved = "保存済み"
        var id: String { rawValue }
        var title: String { LKey(rawValue) }
        var explanation: String {
            switch self {
            case .managed: L("このアプリで追加した壁紙です。タップして確認・削除できます。")
            case .gallery: L("標準の壁紙を含む、壁紙の追加画面に表示される候補です。")
            case .saved: L("端末にあるロック画面のデータです。現在選択中とは限りません。変更はiOSのロック画面から行ってください。")
            }
        }
    }

    private var items: [InstalledWallpaper] {
        (library.result?.snapshot.items ?? []).filter {
            let included = switch filter {
            case .managed: $0.isManaged
            case .gallery: $0.location.isGallery
            case .saved: $0.location == .configurations
            }
            return included && $0.isVisible(showPhotosAndVideos: showPhotosAndVideos) &&
                (search.isEmpty || $0.title.localizedStandardContains(search) ||
                                WallpaperDisplay.provider($0.provider).localizedStandardContains(search))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let snapshot = library.result?.snapshot,
                   snapshot.refreshRequired || (snapshot.latestChange?.timeIntervalSince1970 ?? 0) > acknowledged {
                    activationCard(snapshot)
                }
                if let error = actionError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if library.loading {
                    HStack {
                        ProgressView()
                        Text("壁紙を読み込み中… \(String(describing: library.processedCount))件").foregroundStyle(.secondary)
                        Spacer()
                        Button("中止") { pauseLoading() }
                    }
                        .frame(maxWidth: .infinity).padding(.vertical)
                }
                if paused {
                    HStack {
                        Text("読み込みを中止しました。").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("再開") { requestReload() }
                    }
                }
                if let error = library.error {
                    ContentUnavailableView {
                        Label("壁紙を読み込めません", systemImage: "photo.badge.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("もう一度探す") { requestReload() }.buttonStyle(.bordered)
                    }
                } else if library.result != nil {
                    Picker("表示する壁紙", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("\(String(describing: filter.title)) · \(String(describing: items.count))件").font(.headline)
                        Spacer()
                    }
                    if items.isEmpty && (library.loading || paused) && !library.hasCompleteSnapshot {
                        Text(library.loading ? L("取得した壁紙から順に表示します。他の画面も操作できます。") : L("再開すると残りの壁紙を読み込みます。"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if items.isEmpty {
                        ContentUnavailableView {
                            Label(emptyTitle, systemImage: "photo.on.rectangle")
                        } description: {
                            Text(emptyDescription)
                        } actions: {
                            if !search.isEmpty {
                                Button("検索をクリア") { search = "" }
                            } else {
                                Button("一覧を更新") { requestReload() }.buttonStyle(.bordered)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(items) { item in
                                Button { selection = item } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        WallpaperArtwork(key: item.id + String(library.revision)) {
                                            try await model.accessManager.wallpaperThumbnail(item)
                                        }
                                        .frame(height: 210)
                                        .overlay(alignment: .topLeading) {
                                            if item.isManaged {
                                                Text("追加済み").font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 5)
                                                    .background(.ultraThinMaterial, in: Capsule()).padding(10)
                                            }
                                        }
                                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(WallpaperDisplay.provider(item.provider)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.title)、\(item.isManaged ? "このアプリで追加" : WallpaperDisplay.provider(item.provider))")
                            }
                        }
                    }
                    if !library.loading && !library.hasCompleteSnapshot && !items.isEmpty {
                        Text("読み込み途中の一覧を表示しています。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(filter.explanation).font(.caption).foregroundStyle(.secondary)
                    if !showPhotosAndVideos {
                        Text("写真・ビデオは非表示です。右上のメニューから表示できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if library.result!.snapshot.unreadableCount > 0 {
                        Label("一部の壁紙情報を読み取れませんでした。表示件数は実際より少ない場合があります。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                        DisclosureGroup("読み込みの詳細") {
                            let details = library.result!.snapshot.issues.map(\.summary).joined(separator: "\n\n")
                            Text(details).font(.caption).textSelection(.enabled)
                        }.font(.subheadline)
                    }
                }
            }.padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("壁紙")
        .searchable(text: $search, prompt: "壁紙を検索")
        .toolbar {
            Menu {
                Button("tendie・Batterを追加", systemImage: "plus") { showImport = true }
                    .disabled(library.result == nil || model.busy)
                Toggle("写真・ビデオを表示", isOn: $showPhotosAndVideos)
                Button("一覧を更新", systemImage: "arrow.clockwise") { requestReload() }
                if library.loading { Button("読み込みを中止", systemImage: "stop.circle") { pauseLoading() } }
                Button("壁紙が表示されない場合…", systemImage: "arrow.triangle.2.circlepath") { prepareRefresh() }
                    .disabled(library.result == nil)
                NavigationLink("バックアップと復元") { BackupsView(initialSearch: "Poster") }
            } label: { Image(systemName: "ellipsis.circle") }
                .disabled(model.busy || preparing)
                .accessibilityLabel("壁紙の管理")
        }
        .refreshable {
            paused = false
            await reload(force: true)
        }
        .sheet(isPresented: $showImport, onDismiss: { reloadID = UUID() }) {
            if let container = library.result?.container {
                NavigationStack { WallpaperImportView(container: container) }
            }
        }
        .sheet(item: $selection, onDismiss: { reloadID = UUID() }) { item in
            NavigationStack { WallpaperDetailView(item: item) }
        }
        .fileWriteConfirmation(request: $request) { reloadID = UUID() }
        .onAppear { visible = true }
        .task(id: refreshRequest, priority: .utility) {
            guard !Task.isCancelled else { return }
            guard refreshRequest.active else { library.cancel(clearResult: false); return }
            await reload()
        }
        .onChange(of: model.busy) { old, busy in
            if old && !busy && preparing { preparing = false; reloadID = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                generation = UUID()
                library.cancel(clearResult: false)
                if let request { Task { await model.accessManager.cancelWrite(request) }; self.request = nil }
            } else if phase == .active { reloadID = UUID() }
        }
        .onDisappear { visible = false; generation = UUID(); library.cancel(clearResult: false) }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return L("一致する壁紙はありません") }
        if (library.result?.snapshot.unreadableCount ?? 0) > 0 { return L("この一覧の壁紙を確認できません") }
        if filter == .managed { return L("追加した壁紙はまだありません") }
        return filter == .gallery ? L("ギャラリーのデータを取得できませんでした") : L("保存済みのデータが見つかりませんでした")
    }

    private var emptyDescription: String {
        if (library.result?.snapshot.unreadableCount ?? 0) > 0 {
            return L("読み取れなかった情報があります。「読み込みの詳細」を確認するか、一覧を更新してください。")
        }
        if filter == .managed && search.isEmpty { return L("tendieファイルからお気に入りの壁紙を追加しましょう。") }
        if search.isEmpty, !showPhotosAndVideos {
            return L("写真・ビデオは右上のメニューから表示できます。それ以外の壁紙が見つからない場合は一覧を更新してください。")
        }
        if search.isEmpty { return L("右上のメニューや下のボタンから一覧を更新してください。") }
        return L("検索条件を変更してください。")
    }

    private func activationCard(_ snapshot: WallpaperLibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(snapshot.refreshRequired ? L("表示の更新をやり直してください") : L("あと一歩で反映できます"),
                  systemImage: snapshot.refreshRequired ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .font(.headline)
            Text(snapshot.refreshRequired ?
                 L("壁紙は変更されましたが、表示の更新準備が完了していません。先に「表示を更新」を実行してください。") :
                 L("表示の更新準備は完了しています。作業を保存してリスプリングしたあと、ロック画面を長押しして「＋」から確認してください。"))
                .font(.subheadline).foregroundStyle(.secondary)
            if snapshot.refreshRequired {
                Button("表示を更新…") { prepareRefresh() }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || preparing)
            } else {
                NavigationLink("リスプリングして反映") { RespringSettingsView() }.buttonStyle(.borderedProminent)
                Button("ロック画面で確認しました") { acknowledged = Date().timeIntervalSince1970 }
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func reload(force: Bool = false) async {
        let previousRevision = library.revision
        let existing = library.result?.container
        await library.refresh(fileRevision: model.fileWriteRevision, force: force || forceReload) { publish in
            let target: (container: String, storePath: String?)
            if let existing {
                target = (existing, nil)
            } else {
                let catalog = try await model.loadApplications()
                let paths = Set(catalog.catalog.applications.filter { $0.bundleID == "com.apple.PosterBoard" && $0.kind == .application }
                    .flatMap(\.containerPaths).compactMap { try? WallpaperPaths.container($0) })
                guard !paths.isEmpty else { throw RunnerError(localized: "PosterBoardが見つかりません。端末の設定で壁紙画面を開いてから、もう一度お試しください。") }
                var readable: [String] = []
                var lastError: Error?
                for path in paths.sorted() {
                    do {
                        _ = try await model.accessManager.readWallpaperDirectory(path: path + "/" + WallpaperPaths.store + "/Extensions", container: path)
                        readable.append(path)
                    } catch is CancellationError { throw CancellationError() }
                    catch { lastError = error }
                }
                guard readable.count == 1 else {
                    if readable.isEmpty, let lastError { throw lastError }
                    throw RunnerError(localized: "PosterBoardの場所を一意に確認できませんでした。端末の壁紙設定を開いてから再試行してください。")
                }
                target = (readable[0], catalog.sourcePath)
            }
            try Task.checkCancellation()
            await publish(WallpaperLibraryLoad(container: target.container, storePath: target.storePath,
                snapshot: WallpaperLibrarySnapshot(items: [], unreadableCount: 0, latestChange: nil, refreshRequired: false)))
            let snapshot = try await model.accessManager.readWallpaperLibrary(container: target.container) { partial in
                await publish(WallpaperLibraryLoad(container: target.container, storePath: target.storePath, snapshot: partial))
            }
            return WallpaperLibraryLoad(container: target.container, storePath: target.storePath, snapshot: snapshot)
        }
        guard !Task.isCancelled else { return }
        forceReload = false
        if let error = library.error { model.log("壁紙一覧: \(String(describing: error))", error: true); return }
        guard library.revision != previousRevision else { return }
        if let snapshot = library.result?.snapshot, snapshot.unreadableCount > 0 {
            model.log("壁紙一覧: \(String(describing: snapshot.items.count))件を取得、\(String(describing: snapshot.unreadableCount))件の読み取り失敗\n" +
                      snapshot.issues.map(\.summary).joined(separator: "\n\n"), error: true)
        }
        if let snapshot = library.result?.snapshot, !snapshot.items.contains(where: { $0.location.isGallery }),
           let diagnostics = snapshot.diagnostics {
            model.log("壁紙ギャラリー0件の診断:\n" + diagnostics.report)
        }
    }

    private func pauseLoading() {
        paused = true
        library.cancel(clearResult: false)
    }

    private func requestReload() {
        paused = false
        forceReload = true
        reloadID = UUID()
    }

    private func prepareRefresh() {
        guard let container = library.result?.container, !model.busy, !preparing else { return }
        library.invalidateCache()
        preparing = true
        actionError = nil
        let token = generation
        model.run(L("壁紙の表示を更新")) {
            do {
                let result = try await model.accessManager.prepareWallpaperRefresh(container: container)
                guard generation == token else { await model.accessManager.cancelWrite(result); return }
                request = result
            } catch {
                guard generation == token else { return }
                actionError = error.localizedDescription
                model.log(error.localizedDescription, error: true)
            }
        }
    }
}

private struct WallpaperArtwork: View {
    let key: String
    let load: () async throws -> Data?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.18), .blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text("プレビューなし").font(.caption2)
                    }.foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .task(id: key) {
            image = nil
            do {
                let bytes = try await load()
                guard !Task.isCancelled else { return }
                image = bytes.flatMap(UIImage.init(data:))
            } catch { /* Private animated formats and unavailable assets keep the placeholder. */ }
        }
        .accessibilityHidden(true)
    }
}

private struct WallpaperImportView: View {
    let container: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var archive: WallpaperArchive?
    @State private var selectedID = ""
    @State private var batterSelections = BatterSelections()
    @State private var showPicker = false
    @State private var request: FileWriteRequest?
    @State private var errorMessage: String?
    @State private var added = false
    @State private var generation = UUID()
    private var selected: WallpaperDescriptor? { archive?.descriptors.first { $0.id == selectedID } }

    var body: some View {
        Form {
            if added {
                Section {
                    Label("壁紙を追加しました", systemImage: "checkmark.circle.fill").foregroundStyle(.teal).font(.headline)
                    Text("表示の更新準備も完了しました。壁紙一覧に戻り、リスプリングして反映してください。").font(.subheadline)
                    Button("壁紙一覧に戻る") { dismiss() }
                }
            } else {
                Section {
                    Button { showPicker = true } label: { Label(archive == nil ? L("壁紙ファイルを選択") : L("別のファイルを選択"), systemImage: "doc.badge.plus") }
                    if let archive { Text(archive.url.lastPathComponent).font(.subheadline).foregroundStyle(.secondary) }
                } footer: {
                    Text("tendie / tendies / PosterBoard用Batterに対応しています。同じ中身の.zipファイルも選択できます。")
                }
                if let archive {
                    if let template = archive.template {
                        BatterOptionsView(template: template, selections: $batterSelections)
                            .disabled(request != nil)
                        let previews = template.visiblePreviews(batterSelections)
                        if !previews.isEmpty {
                            Section("テンプレートの参考画像") {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 12) {
                                        ForEach(previews, id: \.self) { name in
                                            WallpaperArtwork(key: archive.url.path + name) {
                                                try await model.accessManager.batterPreview(name, archive: archive)
                                            }.frame(width: 140, height: 210)
                                        }
                                    }
                                }
                                Text("色や差し替え画像を合成した実表示ではありません。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("追加する壁紙 · \(String(describing: archive.descriptors.count))件") {
                        ForEach(archive.descriptors) { descriptor in
                            Button { selectedID = descriptor.id } label: {
                                HStack(spacing: 14) {
                                    WallpaperArtwork(key: descriptor.id) {
                                        try await model.accessManager.wallpaperPackageThumbnail(descriptor, archive: archive)
                                    }.frame(width: 62, height: 92)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(descriptor.title).font(.headline).foregroundStyle(.primary)
                                        Text(WallpaperDisplay.provider(descriptor.provider)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedID == descriptor.id ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                }.padding(.vertical, 4)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityAddTraits(selectedID == descriptor.id ? .isSelected : [])
                        }
                    }
                }
                Section {
                    Text("同じ名前の壁紙は上書きせず、新しい壁紙として追加します。表示の更新準備も自動で行います。")
                        .font(.subheadline)
                    Text("信頼できる壁紙だけを使用してください。端末によっては表示できない場合があります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) } }
            if model.busy { Section { ProgressView("壁紙を準備中…") } }
        }
        .navigationTitle("壁紙ファイルを追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("閉じる") { dismiss() }.disabled(model.busy) }
        .safeAreaInset(edge: .bottom) {
            if !added {
                Button("選択した壁紙を追加") { prepareImport() }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    .disabled(selected == nil || model.busy || request != nil)
                    .padding().background(.bar)
            }
        }
        .disabled(model.busy)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip, .data], allowsMultipleSelection: false) { result in
            do { if let url = try result.get().first { inspect(url) } }
            catch { errorMessage = error.localizedDescription }
        }
        .fileWriteConfirmation(request: $request) { added = true }
        .onDisappear { invalidate() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { invalidate() } }
    }

    private func inspect(_ url: URL) {
        let token = generation
        archive = nil
        selectedID = ""
        batterSelections = BatterSelections()
        errorMessage = nil
        model.run(L("壁紙ファイルを確認")) {
            do {
                let result = try await model.accessManager.inspectWallpaperArchive(url)
                guard generation == token else { return }
                archive = result
                selectedID = result.descriptors.first?.id ?? ""
            } catch {
                guard generation == token else { return }
                errorMessage = error.localizedDescription
                model.log(error.localizedDescription, error: true)
            }
        }
    }

    private func prepareImport() {
        guard let archive, let selected else { return }
        model.wallpaperLibrary.invalidateCache()
        let token = generation
        errorMessage = nil
        model.run(L("壁紙を追加")) {
            do {
                let result = try await model.accessManager.prepareWallpaperImport(selected, archive: archive, container: container,
                                                                                 selections: batterSelections)
                guard generation == token else { await model.accessManager.cancelWrite(result); return }
                request = result
            } catch {
                guard generation == token else { return }
                errorMessage = error.localizedDescription
                model.log(error.localizedDescription, error: true)
            }
        }
    }

    private func invalidate() {
        generation = UUID()
        archive = nil
        selectedID = ""
        batterSelections = BatterSelections()
        if let request { Task { await model.accessManager.cancelWrite(request) }; self.request = nil }
    }
}

private struct WallpaperDetailView: View {
    let item: InstalledWallpaper
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var request: FileWriteRequest?
    @State private var deleted = false
    @State private var errorMessage: String?
    @State private var generation = UUID()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                WallpaperArtwork(key: item.id) { try await model.accessManager.wallpaperThumbnail(item) }
                    .frame(width: 240, height: 350)
                Text(item.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(WallpaperDisplay.provider(item.provider)).foregroundStyle(.secondary)
                Text(item.location == .configurations ? L("保存済みのロック画面データ") : (item.isManaged ? L("このアプリで追加した壁紙") : L("端末の壁紙ギャラリー")))
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary, in: Capsule())
                Text("プレビューは壁紙に含まれる画像です。実際の表示やアニメーションとは異なる場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
                if deleted {
                    Label("壁紙を削除しました", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                    Text("一覧に戻り、リスプリングして変更を反映してください。").font(.subheadline)
                } else if item.isManaged {
                    Button("この壁紙を削除…", role: .destructive) { prepareDeletion() }
                        .buttonStyle(.bordered).controlSize(.large)
                    Text("削除前にバックアップします。保存済みのロック画面は変更しません。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("このアプリで追加した壁紙ではないため、ここから削除できません。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(maxWidth: .infinity).padding(24)
        }
        .navigationTitle("壁紙の詳細").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("閉じる") { dismiss() }.disabled(model.busy) }
        .disabled(model.busy)
        .fileWriteConfirmation(request: $request) { deleted = true }
        .onDisappear { invalidate() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { invalidate() } }
    }

    private func prepareDeletion() {
        model.wallpaperLibrary.invalidateCache()
        let token = generation
        errorMessage = nil
        model.run(L("追加した壁紙を削除")) {
            do {
                let result = try await model.accessManager.prepareWallpaperDeletion(item)
                guard generation == token else { await model.accessManager.cancelWrite(result); return }
                request = result
            } catch {
                guard generation == token else { return }
                errorMessage = error.localizedDescription
                model.log(error.localizedDescription, error: true)
            }
        }
    }

    private func invalidate() {
        generation = UUID()
        if let request { Task { await model.accessManager.cancelWrite(request) }; self.request = nil }
    }
}
