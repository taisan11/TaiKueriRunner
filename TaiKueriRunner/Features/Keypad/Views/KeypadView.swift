import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct KeypadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: KeypadLibrarySnapshot?
    @State private var theme: KeypadTheme?
    @State private var overrides: [KeypadKey: Data] = [:]
    @State private var previews: [KeypadKey: Data] = [:]
    @State private var circular = false
    @State private var loading = false
    @State private var working = false
    @State private var visible = false
    @State private var applied = false
    @State private var error: String?
    @State private var progress = ""
    @State private var showImporter = false
    @State private var importKey: KeypadKey?
    @State private var request: FileWriteRequest?
    @State private var reloadID = UUID()
    @State private var loadID = UUID()
    @State private var editID = UUID()
    @State private var editTask: Task<Void, Never>?
    @State private var exportKey: KeypadKey?
    @State private var showExport = false

    private struct LoadRequest: Equatable {
        let active: Bool
        let revision: Int
        let reload: UUID
    }
    private var loadRequest: LoadRequest {
        LoadRequest(active: visible && scenePhase == .active && model.selectedTab == .home && !model.busy,
                    revision: model.browserRevision, reload: reloadID)
    }
    private var options: KeypadRenderOptions {
        KeypadRenderOptions(circular: circular)
    }
    private var changedKeys: Set<KeypadKey> { (theme?.keys ?? []).union(overrides.keys) }

    var body: some View {
        Form {
            Section {
                Label("電話アプリのキーパッド", systemImage: "phone")
            }.disabled(working || model.busy || request != nil)
            if loading { Section { ProgressView(progress.isEmpty ? L("キー画像を確認中…") : progress) } }
            if let snapshot {
                Section {
                    Text("確認済み: \(String(describing: Set(snapshot.files.map { $0.name.key }).count))キー / \(String(describing: snapshot.files.count))ファイル")
                        .font(.subheadline)
                    Button("ファイルビューワーで開く", systemImage: "folder") {
                        if let path = snapshot.directoryPath { model.browse(path) }
                    }.disabled(snapshot.directoryPath == nil || loading || working || model.busy || request != nil)
                    if snapshot.files.isEmpty {
                        Text("電話アプリのキーパッドを一度開き、外観を切り替えてから再読み込みしてください。")
                            .font(.callout)
                    }
                    if !snapshot.issues.isEmpty {
                        DisclosureGroup("読み取りの詳細") {
                            Text(snapshot.issues.joined(separator: "\n\n")).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            Section("キー画像") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                    ForEach(KeypadKey.allCases) { key in
                        Button {
                            importKey = key
                            showImporter = true
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Circle().fill(.quaternary)
                                    if let bytes = previews[key] ?? snapshot?.previews[key], let image = UIImage(data: bytes) {
                                        Image(uiImage: image).resizable().scaledToFit().padding(3)
                                    } else { Text(key.rawValue).font(.largeTitle).foregroundStyle(.primary) }
                                }
                                .frame(width: 76, height: 76)
                                .overlay(Circle().stroke(changedKeys.contains(key) ? Color.teal : Color.clear, lineWidth: 2))
                                Text(key.rawValue + (changedKeys.contains(key) ? L("・変更") : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("キー\(String(describing: key.rawValue))の画像を選択")
                        .contextMenu {
                            Button("このキーの既存画像を保存", systemImage: "square.and.arrow.down") {
                                exportKey = key
                                showExport = true
                            }.disabled(snapshot?.files.contains(where: { $0.name.key == key }) != true || loading)
                            if overrides[key] != nil { Button("個別画像の変更を取り消す") { overrides.removeValue(forKey: key); refreshPreviews() } }
                        }
                    }
                }
                Text("キーをタップして画像を選択できます。プレビューは実際の表示とは異なります。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("テーマを読み込む（.passthm）", systemImage: "square.and.arrow.down") {
                    importKey = nil
                    showImporter = true
                }
                if let theme { Text(theme.title).font(.subheadline).foregroundStyle(.secondary) }
                Button("未適用の画像変更をクリア", role: .destructive) {
                    theme = nil; overrides = [:]; previews = [:]; applied = false
                }.disabled(changedKeys.isEmpty)
            }.disabled(working || model.busy || request != nil)
            Section("画像の調整") {
                Toggle("円形に切り抜く", isOn: $circular)
            }.disabled(working || model.busy || request != nil)
            if working { Section { ProgressView("画像と変更内容を準備中…") } }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if applied {
                Section {
                    Label("キー画像の書き込みが完了しました", systemImage: "checkmark.circle").foregroundStyle(.teal)
                    Text("電話アプリを開き、外観を切り替えて確認してください。反映されない場合は端末を再起動してください。電話アプリの強制終了は避けてください。").font(.callout)
                }
            }
            Section {
                Button("変更を確認して適用") { prepareApply() }
                    .disabled(snapshot?.files.isEmpty != false || changedKeys.isEmpty || loading || working || model.busy || request != nil)
                Button("端末の画像を再読み込み") { reloadID = UUID() }
                    .disabled(loading || working || model.busy || request != nil)
                Button("既存画像を保存", systemImage: "square.and.arrow.down") {
                    exportKey = nil
                    showExport = true
                }.disabled(snapshot?.files.isEmpty != false || loading || working || model.busy || request != nil)
                NavigationLink("バックアップ・元の画像を復元") { BackupsView(initialSearch: "TelephonyUI") }
            }
        }
        .navigationTitle("電話のキーパッド")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            if let snapshot {
                NavigationStack { KeypadExportView(snapshot: snapshot, key: exportKey) }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKey == nil ? [.data] : [.image], allowsMultipleSelection: false) { result in
            do { if let url = try result.get().first { importFile(url, key: importKey) } }
            catch { self.error = error.localizedDescription }
        }
        .fileWriteConfirmation(request: $request) {
            applied = true
            theme = nil; overrides = [:]; previews = [:]
            reloadID = UUID()
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; invalidate() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { invalidate() } }
        .onChange(of: model.selectedTab) { _, tab in if tab != .home { invalidate() } }
        .onChange(of: circular) { _, _ in refreshPreviews() }
        .task(id: loadRequest, priority: .utility) {
            guard !Task.isCancelled, loadRequest.active else { return }
            await load()
        }
    }

    private func load() async {
        let token = UUID()
        loadID = token; loading = true; progress = ""; error = nil
        defer { if loadID == token { loading = false } }
        do {
            let catalog = try await model.loadApplications { message in
                await MainActor.run { if loadID == token { progress = message } }
            }
            try Task.checkCancellation()
            let containers = Set(catalog.catalog.applications.filter { $0.bundleID == "com.apple.mobilephone" && $0.kind == .application }
                .flatMap(\.containerPaths).compactMap { try? WallpaperPaths.container($0) })
            guard containers.count == 1, let container = containers.first else {
                throw RunnerError(localized: "電話アプリのデータコンテナを一意に確認できません。電話アプリを開いてから再試行してください。")
            }
            let directories = [try KeypadPaths.phoneDirectory(container)]
            let result = try await model.keypadService.load(directories: directories)
            try Task.checkCancellation()
            guard loadID == token else { return }
            snapshot = result
        } catch is CancellationError {}
        catch { if loadID == token { self.error = error.localizedDescription } }
    }

    private func startEdit(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        editTask?.cancel()
        let token = UUID(); editID = token; working = true; error = nil; applied = false
        editTask = Task(priority: .utility) {
            defer { if editID == token { working = false; editTask = nil } }
            do { try await operation(token) }
            catch is CancellationError {}
            catch { if editID == token { self.error = error.localizedDescription } }
        }
    }

    private func importFile(_ url: URL, key: KeypadKey?) {
        startEdit { token in
            if let key {
                let data = try await model.keypadService.readImage(url)
                try Task.checkCancellation()
                guard editID == token else { return }
                let bytes = overrides.filter { $0.key != key }.values.reduce(0) { $0 + $1.count } +
                    (theme?.assets.reduce(0) { $0 + $1.data.count } ?? 0) + data.count
                guard bytes <= 128 * 1024 * 1024 else { throw RunnerError(localized: "編集用画像の合計は128 MiBまでです。テーマまたは個別画像をクリアしてください。") }
                overrides[key] = data
            } else {
                let imported = try await model.keypadService.readTheme(url)
                try Task.checkCancellation()
                guard editID == token else { return }
                theme = imported; overrides = [:]
            }
            let result = try await model.keypadService.preview(theme: theme, overrides: overrides, options: options)
            try Task.checkCancellation()
            if editID == token { previews = result }
        }
    }

    private func refreshPreviews() {
        guard !changedKeys.isEmpty else { previews = [:]; return }
        startEdit { token in
            let result = try await model.keypadService.preview(theme: theme, overrides: overrides, options: options)
            try Task.checkCancellation()
            if editID == token { previews = result }
        }
    }

    private func prepareApply() {
        guard let snapshot else { return }
        startEdit { token in
            let plan = try await model.keypadService.plan(snapshot: snapshot, theme: theme, overrides: overrides, options: options)
            try Task.checkCancellation()
            let prepared = try await model.accessManager.prepareKeypadChange(plan)
            guard !Task.isCancelled, editID == token else { await model.accessManager.cancelWrite(prepared); return }
            request = prepared
        }
    }

    private func invalidate() {
        loadID = UUID(); loading = false
        editID = UUID(); editTask?.cancel(); editTask = nil; working = false
        if let request { Task { await model.accessManager.cancelWrite(request) }; self.request = nil }
    }
}
