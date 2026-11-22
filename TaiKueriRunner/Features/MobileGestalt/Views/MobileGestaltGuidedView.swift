import SwiftUI

struct MobileGestaltView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var gestalt = MobileGestaltModel()
    @State private var visible = false
    @State private var confirmReload = false
    @State private var search = ""

    var body: some View {
        let supportedFeatures = gestalt.document.map { MobileGestaltFeature.available(in: $0) } ?? []
        let featuresMatchingSearch = MobileGestaltFeature.all.filter { $0.matches(search: search) }
        List {
            Section {
                Text("実機での安全性は未検証です")
                    .foregroundStyle(.orange)
                Text("全\(String(describing: MobileGestaltFeature.all.count))項目を表示 / 編集可能 \(String(describing: supportedFeatures.count))項目")
                    .font(.subheadline)
                Text("未設定のキーを変更した場合そのキーを自動で追加します。実際に対応しているかどうかは環境によるのでご注意ください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if gestalt.loading || (gestalt.document == nil && gestalt.errorMessage == nil) {
                ProgressView("端末の設定を確認中…")
            }
            if let error = gestalt.errorMessage {
                Section("読み込み・編集の状況") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            if gestalt.document == nil && !gestalt.loading && gestalt.errorMessage != nil {
                Section {
                    Text("設定を読み込めません").font(.headline)
                    Text("再読み込みするか、詳細エディタでPlistを選択してください。")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(MobileGestaltFeature.Category.allCases) { category in
                let features = featuresMatchingSearch.filter { $0.category == category }
                if !features.isEmpty {
                    Section("\(category.title)（\(features.count)）") {
                        ForEach(features) { feature in
                            MGFeatureControl(gestalt: gestalt, feature: feature)
                        }
                    }
                }
            }
            if featuresMatchingSearch.isEmpty {
                Text("一致する設定はありません")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("再読み込み") {
                    if gestalt.document?.changes.isEmpty == false { confirmReload = true }
                    else { Task { await reload() } }
                }
                NavigationLink { BackupsView(initialSearch: gestalt.document?.path ?? MobileGestaltDocument.defaultPath) } label: {
                    Text("バックアップ・復元")
                }
                NavigationLink { RespringSettingsView() } label: {
                    Text("リスプリング")
                }
            } header: { Text("管理") }
            Section {
                NavigationLink { MobileGestaltAdvancedView(gestalt: gestalt) } label: {
                    Text("Plist詳細エディタ・ファイル選択")
                }
            } header: { Text("詳細") }
        }
        .navigationTitle("MobileGestalt")
        .searchable(text: $search, prompt: "機能名・カテゴリ・MGキーを検索")
        .toolbar {
            if let document = gestalt.document, !document.changes.isEmpty {
                NavigationLink { MGFeatureReviewView(gestalt: gestalt) } label: {
                    Text("保存（\(String(describing: document.changes.count))）")
                }
            }
        }
        .disabled(gestalt.loading || model.busy)
        .onAppear {
            visible = true
            refreshIfNeeded()
        }
        .onDisappear { visible = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshIfNeeded() }
        }
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .home { refreshIfNeeded() }
        }
        .onChange(of: model.browserRevision) { _, _ in refreshIfNeeded() }
        .onChange(of: model.busy) { _, busy in
            if !busy { refreshIfNeeded() }
        }
        .alert("下書きを破棄して再読み込みしますか？", isPresented: $confirmReload) {
            Button("破棄して再読み込み", role: .destructive) {
                gestalt.discardChanges()
                Task { await reload() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("未適用の変更は失われます。") }
    }

    private func refreshIfNeeded() {
        guard visible, !model.busy, !gestalt.loading else { return }
        Task { await gestalt.refresh { try await readCurrentDocument() } }
    }

    private func reload() async {
        await gestalt.load { try await readCurrentDocument() }
    }

    private func readCurrentDocument() async throws -> MobileGestaltDocument {
        let path = gestalt.document?.path ?? MobileGestaltDocument.defaultPath
        if path == MobileGestaltDocument.defaultPath && ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            throw RunnerError(localized: "iOS 26では端末の設定を読み込めません。詳細エディタでPlistのコピーを選択してください。")
        }
        return try await model.accessManager.readMobileGestalt(path: path)
    }
}

private struct MGFeatureControl: View {
    let gestalt: MobileGestaltModel
    let feature: MobileGestaltFeature
    @Environment(AppModel.self) private var model
    private var selection: String? { gestalt.document.flatMap { feature.selection(in: $0) } }
    private var input: String { gestalt.document.flatMap { try? feature.values(in: $0).first?.summary } ?? "" }
    private var changed: Bool {
        gestalt.document?.changes.values.contains { entry in feature.fields.contains { $0.path == entry.path } } == true
    }

    var body: some View {
        let issue = feature.editingIssue(in: gestalt.document)
        VStack(alignment: .leading, spacing: 8) {
            if let issue {
                heading
                Text("編集不可：\(String(describing: issue))").font(.caption).foregroundStyle(.secondary)
            } else {
                switch feature.control {
                case .toggle where selection != nil:
                    Toggle(isOn: Binding(get: { selection == "on" }, set: { enabled in
                        update { try gestalt.stage(feature, choice: enabled ? "on" : "off") }
                    })) { heading }
                case .toggle, .picker:
                    Picker(selection: Binding(get: { selection ?? "" }, set: { choice in
                        update { try gestalt.stage(feature, choice: choice) }
                    })) {
                        if selection == nil { Text(currentSummary).tag("") }
                        ForEach(feature.choices) { Text($0.title).tag($0.id) }
                    } label: { heading }
                case .text:
                    heading
                    TextField(feature.title, text: Binding(get: { input }, set: { value in
                        update { try gestalt.stage(feature, input: value) }
                    }))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(feature.title)
                case .number:
                    heading
                    TextField(feature.title, value: Binding<Int64>(get: { Int64(input) ?? 0 }, set: { value in
                        update { try gestalt.stage(feature, input: String(value)) }
                    }), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad).accessibilityLabel(feature.title)
                }
            }
            Text(feature.explanation).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if changed {
                Button("この設定の変更を取り消す") {
                    update { try gestalt.reset(feature) }
                }
            }
        }
    }

    private var heading: some View {
        HStack {
            Text(feature.title)
            if changed { Text("未保存").font(.caption).foregroundStyle(.teal) }
        }
    }

    private var currentSummary: String {
        gestalt.document.flatMap { try? feature.summary(in: $0) } ?? L("現在の値")
    }

    private func update(_ operation: () throws -> Void) {
        do { try operation(); gestalt.errorMessage = nil }
        catch { model.report(error) }
    }
}

private struct MGFeatureReviewView: View {
    let gestalt: MobileGestaltModel
    @Environment(AppModel.self) private var model
    @State private var request: FileWriteRequest?
    @State private var saveData = Data()
    @State private var confirmDiscard = false

    private var validationError: String? {
        guard let document = gestalt.document else { return L("設定が読み込まれていません。") }
        do { try MobileGestaltFeature.validateGuidedChanges(in: document); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        Form {
            if let document = gestalt.document {
                Section("変更内容") {
                    ForEach(MobileGestaltFeature.changed(in: document)) { feature in
                        LabeledContent(feature.title, value: "\((try? feature.summary(in: document, original: true)) ?? "—") → \((try? feature.summary(in: document)) ?? "—")")
                    }
                    if document.changes.values.contains(where: { MobileGestaltFeature.feature(at: $0.path) == nil }) {
                        Text("詳細エディタの変更")
                    }
                    if document.changes.isEmpty { Text("変更はありません。") }
                }
                Section("保存先") { Text(document.path).font(.caption).textSelection(.enabled) }
            }
            Section {
                if let validationError { Text(validationError).foregroundStyle(.red) }
                Button("変更を適用") { prepareSave() }
                    .disabled(validationError != nil || gestalt.document?.changes.isEmpty != false || model.busy || gestalt.loading || request != nil)
                Button("すべての下書きを破棄", role: .destructive) { confirmDiscard = true }
                    .disabled(model.busy || request != nil || gestalt.loading)
            }
        }
        .navigationTitle("変更を確認・適用").navigationBarTitleDisplayMode(.inline)
        .disabled(request != nil)
        .alert("すべての下書きを破棄しますか？", isPresented: $confirmDiscard) {
            Button("破棄", role: .destructive) { gestalt.discardChanges() }
            Button("キャンセル", role: .cancel) {}
        }
        .fileWriteConfirmation(request: $request) { gestalt.acceptSaved(saveData) }
    }

    private func prepareSave() {
        guard let document = gestalt.document, !document.changes.isEmpty else { return }
        model.run(L("機能別設定の保存確認を準備")) {
            try MobileGestaltFeature.validateGuidedChanges(in: document)
            saveData = try document.encoded()
            request = try await model.accessManager.prepareWrite(.savePropertyList(path: document.path, data: saveData, original: document.original))
        }
    }
}
