import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Binding var path: String
    let title: String
    @Environment(AppModel.self) private var model
    @AppStorage("showHiddenFiles") private var showHidden = false
    @AppStorage("fileSortOrder") private var sortOrder = FileSortOrder.name
    @AppStorage("fileSortReversed") private var sortReversed = false
    @AppStorage("foldersFirst") private var foldersFirst = true
    @State private var browser = FileBrowserModel()
    @State private var search = ""
    @State private var pathInput = ""
    @State private var locationError: String?
    @State private var showLocations = false
    @State private var folderPrompt = false
    @State private var renameEntry: FileEntry?
    @State private var writeRequest: FileWriteRequest?
    @State private var nameInput = ""
    @State private var previewEntry: FileEntry?
    @State private var shareEntry: FileEntry?
    @State private var pickDirectory = false
    @State private var pickDirectoryAfterDismiss = false
    @State private var importFile = false

    init(path: Binding<String>, title: String = L("ファイル")) {
        self._path = path
        self.title = title
    }

    private var listingOptions: FileListingOptions {
        FileListingOptions(sortOrder: sortOrder, reversed: sortReversed, foldersFirst: foldersFirst)
    }

    private var loadRequest: BrowserLoadRequest {
        BrowserLoadRequest(path: path, showHidden: showHidden, revision: model.browserRevision)
    }

    private var displayRequest: BrowserDisplayRequest {
        BrowserDisplayRequest(revision: browser.snapshotRevision, search: search, options: listingOptions)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if path != "/" {
                        Button {
                            navigate((path as NSString).deletingLastPathComponent)
                        } label: {
                            Image(systemName: "arrow.up").frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("上の階層へ")
                        .contextMenu {
                            ForEach(FileRules.ancestorPaths(of: path), id: \.self) { ancestor in
                                Button(ancestor) { navigate(ancestor) }
                            }
                        }
                    }
                    Button { presentLocations() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(path == "/" ? "/" : (path as NSString).lastPathComponent)
                                .font(.headline).foregroundStyle(.primary).lineLimit(1)
                            Text(path).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("現在の場所: \(String(describing: path))。場所を変更")
                    if browser.loading || browser.arranging { ProgressView() }
                }
            } footer: {
                HStack {
                    Text(search.isEmpty ? L("\(String(describing: browser.entries.count))項目") : L("\(String(describing: browser.visibleEntries.count)) / \(String(describing: browser.entries.count))項目"))
                }.font(.caption)
            }
            if let loadError = browser.errorMessage {
                Section {
                    ContentUnavailableView("フォルダを開けません", systemImage: "folder.badge.questionmark", description: Text(loadError))
                    Button("実行環境と設定を確認") { model.selectedTab = .settings }
                    NavigationLink("コンテナを探す") { PathEnumerationView(initialPath: path) }
                }
            } else if (browser.loading || browser.arranging) && browser.visibleEntries.isEmpty {
                Text("読み込み中…").foregroundStyle(.secondary)
            } else if browser.visibleEntries.isEmpty && !browser.loading && !browser.arranging {
                ContentUnavailableView(
                    search.isEmpty ? L("フォルダは空です") : L("一致するファイルはありません"),
                    systemImage: search.isEmpty ? "folder" : "magnifyingglass"
                )
            } else {
                Section {
                    ForEach(browser.visibleEntries) { entry in
                        Button {
                            if entry.isDirectory || entry.isSymbolicLink {
                                if entry.isSymbolicLink { openLink(entry) } else { navigate(entry.path) }
                            } else { previewEntry = entry }
                        } label: { fileRow(entry) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("パスをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.path }
                            FileShareButton(entry: entry, selection: $shareEntry)
                            Button("名前を変更", systemImage: "pencil") { nameInput = entry.name; renameEntry = entry }
                            Button("削除", systemImage: "trash", role: .destructive) { requestWrite(.delete(path: entry.path)) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "ファイル名で検索")
        .onChange(of: path) { _, _ in search = "" }
        .refreshable { await reload() }
        .task(id: loadRequest) { await reload() }
        .task(id: displayRequest) { await browser.updateVisible(search: search, options: listingOptions) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("場所") { presentLocations() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("表示") {
                        Menu("並べ替え", systemImage: "arrow.up.arrow.down") {
                            Picker("並べ替え", selection: $sortOrder) {
                                ForEach(FileSortOrder.allCases) { order in Text(order.title).tag(order) }
                            }.pickerStyle(.inline)
                            Toggle("順序を反転", isOn: $sortReversed)
                            Toggle("フォルダを先頭に", isOn: $foldersFirst)
                        }
                        Button("再読み込み", systemImage: "arrow.clockwise") { model.browserRevision += 1 }
                        Toggle("隠しファイルを表示", isOn: $showHidden)
                        Button("現在のパスをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                    }
                    Button("新規フォルダ", systemImage: "folder.badge.plus") { nameInput = ""; folderPrompt = true }
                    Button("ファイルをインポート", systemImage: "square.and.arrow.down") { importFile = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("ファイル操作メニュー")
            }
        }
        .sheet(isPresented: $showLocations, onDismiss: {
            if pickDirectoryAfterDismiss {
                pickDirectoryAfterDismiss = false
                pickDirectory = true
            }
        }) { locationsSheet }
        .alert("新規フォルダ", isPresented: $folderPrompt) {
            TextField("フォルダ名", text: $nameInput)
            Button("作成") {
                let name = nameInput, directory = path
                requestWrite(.createFolder(name: name, directory: directory))
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("名前を変更", isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
            TextField("新しい名前", text: $nameInput)
            Button("変更") {
                guard let entry = renameEntry else { return }
                let name = nameInput
                requestWrite(.rename(path: entry.path, name: name))
                renameEntry = nil
            }
            Button("キャンセル", role: .cancel) { renameEntry = nil }
        }
        .fileWriteConfirmation(request: $writeRequest)
        .sheet(item: $shareEntry) { FileShareView(entry: $0) }
        .sheet(item: $previewEntry) { entry in NavigationStack { FileInspectorView(entry: entry) }.environment(model) }
        .fileImporter(isPresented: $pickDirectory, allowedContentTypes: [.folder]) { result in
            model.run(L("選択したフォルダを開きました。")) {
                let url = try result.get()
                let path = try await model.accessManager.openScopedDirectory(url)
                navigate(path)
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item]) { result in
            do { requestWrite(.importFile(source: try result.get(), directory: path)) }
            catch { model.report(error) }
        }
        .disabled(model.busy)
    }

    private var locationsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("/var/…", text: $pathInput, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("このパスを開く", systemImage: "arrow.right") { openLocation(pathInput) }
                        .disabled(pathInput.isEmpty)
                } header: { Text("パスを指定") }
                Section("場所") {
                    ForEach(PathPreset.availableLocations(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)) { preset in
                        Button { openLocation(preset.path) } label: { PathPresetRow(preset: preset) }
                    }
                    Button("フォルダを選択…", systemImage: "folder.badge.plus") {
                        showLocations = false
                        // Present the system picker after this sheet has closed.
                        pickDirectoryAfterDismiss = true
                    }
                }
            }
            .navigationTitle("場所を開く").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showLocations = false } } }
            .alert("パスを開けません", isPresented: Binding(get: { locationError != nil }, set: { if !$0 { locationError = nil } })) {
                Button("OK", role: .cancel) { locationError = nil }
            } message: { Text(locationError ?? "") }
        }
    }

    private func presentLocations() {
        pathInput = path
        locationError = nil
        showLocations = true
    }

    private func openLocation(_ path: String) {
        do {
            let canonical = try FileRules.canonical(path)
            showLocations = false
            navigate(canonical)
        } catch {
            locationError = error.localizedDescription
            model.log(error.localizedDescription, error: true)
        }
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.icon).font(.title3).foregroundStyle(entry.isDirectory ? .teal : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                Text(entry.isDirectory ? L("フォルダ") : entry.isSymbolicLink ? L("シンボリックリンク") : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 3)
    }

    private func reload() async {
        let service = model.accessManager
        await browser.reload(path: path, showHidden: showHidden) { path, showHidden in
            try await service.list(path: path, showHidden: showHidden)
        }
    }

    private func requestWrite(_ operation: FileWriteOperation) {
        model.run(L("書き込み確認を準備: \(String(describing: operation.title))")) {
            writeRequest = try await model.accessManager.prepareWrite(operation)
        }
    }

    private func navigate(_ destination: String) {
        if path == destination { model.browserRevision += 1 }
        else { path = destination }
    }

    private func openLink(_ entry: FileEntry) {
        model.run(L("リンクを開く: \(String(describing: entry.path))")) {
            let resolved = try await model.accessManager.resolveLink(entry)
            if resolved.isDirectory { navigate(resolved.path) }
            else { previewEntry = resolved }
        }
    }
}
