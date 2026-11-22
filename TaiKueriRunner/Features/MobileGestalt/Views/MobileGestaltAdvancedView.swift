import SwiftUI
import UniformTypeIdentifiers

struct MobileGestaltAdvancedView: View {
    @Environment(AppModel.self) private var model
    let gestalt: MobileGestaltModel
    @State private var pathInput = MobileGestaltDocument.defaultPath
    @State private var search = ""
    @State private var pickFile = false
    @State private var pendingLoad: MGLoadTarget?
    @State private var confirmDiscard = false
    @State private var request: FileWriteRequest?
    @State private var saveData = Data()

    var body: some View {
        List {
            Section {
                TextField("MobileGestalt Plistの絶対パス", text: $pathInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.footnote, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("このファイルを読み込む") { requestLoad(.path(pathInput)) }
                Button("書き出したPlistを選択…") { pickFile = true }
            } header: { Text("キャッシュファイル") } footer: {
                Text("選択したファイルに保存します。")
            }
            if gestalt.loading { ProgressView("MobileGestaltを読み込み中…") }
            if let error = gestalt.errorMessage {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let document = gestalt.document {
                Section {
                    LabeledContent("形式", value: document.formatName)
                    Text(document.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !document.changes.isEmpty {
                        NavigationLink {
                            MGEntriesView(gestalt: gestalt, path: [], changedOnly: true, locked: request != nil)
                        } label: { Text("下書きの変更 \(String(describing: document.changes.count))件を確認") }
                        Button("下書きを破棄", role: .destructive) { pendingLoad = nil; confirmDiscard = true }
                    }
                    NavigationLink { BackupsView(initialSearch: document.path) } label: {
                        Text("このファイルのバックアップ・復元")
                    }
                }
                MGEntryRows(gestalt: gestalt, path: [], search: search, locked: request != nil)
            } else if !gestalt.loading {
                Section {
                    Text("MobileGestaltのキャッシュを開く").font(.headline)
                    Text("端末の既定パス、または書き出したPlistを選んでください。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Plist詳細エディタ")
        .searchable(text: $search, prompt: "対応名・元のキー・値で検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("保存") { prepareSave() }
                    .disabled(gestalt.document?.changes.isEmpty != false || gestalt.loading || model.busy || request != nil)
            }
        }
        .disabled(gestalt.loading || model.busy)
        .onAppear { if let document = gestalt.document { pathInput = document.path } }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): requestLoad(.picked(url))
            case .failure(let error): gestalt.errorMessage = error.localizedDescription
            }
        }
        .alert("下書きの変更を破棄しますか？", isPresented: $confirmDiscard) {
            Button("破棄", role: .destructive) {
                gestalt.discardChanges()
                if let target = pendingLoad { pendingLoad = nil; Task { await load(target) } }
            }
            Button("キャンセル", role: .cancel) { pendingLoad = nil }
        } message: { Text("まだ保存していない変更は失われます。") }
        .fileWriteConfirmation(request: $request) { gestalt.acceptSaved(saveData) }
    }

    private func requestLoad(_ target: MGLoadTarget) {
        if gestalt.document?.changes.isEmpty == false { pendingLoad = target; confirmDiscard = true }
        else { Task { await load(target) } }
    }

    private func load(_ target: MGLoadTarget) async {
        await gestalt.load {
            switch target {
            case .path(let path): return try await model.accessManager.readMobileGestalt(path: path)
            case .picked(let url): return try await model.accessManager.readMobileGestalt(url: url)
            }
        }
        if let document = gestalt.document { pathInput = document.path }
    }

    private func prepareSave() {
        guard let document = gestalt.document else { return }
        model.run(L("MobileGestalt保存の確認を準備")) {
            saveData = try document.encoded()
            request = try await model.accessManager.prepareWrite(.savePropertyList(path: document.path, data: saveData, original: document.original))
        }
    }
}

private enum MGLoadTarget { case path(String), picked(URL) }

private struct MGEntriesView: View {
    let gestalt: MobileGestaltModel
    let path: [PlistPathComponent]
    var changedOnly = false
    let locked: Bool
    @State private var search = ""

    var body: some View {
        List { MGEntryRows(gestalt: gestalt, path: path, search: search, changedOnly: changedOnly, locked: locked) }
            .navigationTitle(changedOnly ? L("下書きの変更") : MGKeyCatalog.name(for: path.last?.label ?? "Root"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "対応名・元のキー・値で検索")
    }
}

private struct MGEntryRows: View {
    let gestalt: MobileGestaltModel
    let path: [PlistPathComponent]
    let search: String
    var changedOnly = false
    let locked: Bool
    @Environment(AppModel.self) private var model

    private var entries: [MobileGestaltEntry] {
        guard let document = gestalt.document else { return [] }
        if changedOnly {
            return document.changes.values.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.key.localizedStandardContains(search) }
                .sorted { $0.location.localizedStandardCompare($1.location) == .orderedAscending }
        }
        return (try? document.entries(at: path, search: search)) ?? []
    }

    var body: some View {
        Section("\(String(describing: entries.count))項目") {
            ForEach(entries) { entry in
                NavigationLink {
                    if entry.value.isContainer {
                        MGEntriesView(gestalt: gestalt, path: entry.path, locked: locked)
                    } else {
                        MGValueEditorView(gestalt: gestalt, entry: entry, locked: locked)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.name).font(.subheadline).foregroundStyle(.primary)
                            if gestalt.document?.changes[entry.id] != nil { Text("未保存").font(.caption).foregroundStyle(.orange) }
                        }
                        if entry.name != entry.key { Text(entry.key).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
                        Text(entry.value.typeName + " · " + (entry.value.summary.isEmpty ? L("（空文字列）") : entry.value.summary))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        if !search.isEmpty || changedOnly { Text(entry.location).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
                .contextMenu {
                    Button("元のキーをコピー") { UIPasteboard.general.string = entry.key }
                    Button("対応名をコピー") { UIPasteboard.general.string = entry.name }
                }
            }
        }
    }
}

private struct MGValueEditorView: View {
    let gestalt: MobileGestaltModel
    let entry: MobileGestaltEntry
    let locked: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var boolean: Bool
    @State private var errorMessage: String?

    init(gestalt: MobileGestaltModel, entry: MobileGestaltEntry, locked: Bool) {
        self.gestalt = gestalt; self.entry = entry; self.locked = locked
        _input = State(initialValue: PlistScalarEditor.input(for: entry.value))
        _boolean = State(initialValue: entry.value == .boolean(true))
    }

    private var editable: Bool {
        if case .data = entry.value { return false }
        return !locked && !gestalt.loading
    }

    var body: some View {
        Form {
            Section("キー") {
                Text(entry.name).font(.headline).textSelection(.enabled)
                Text(entry.key).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Text(entry.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                LabeledContent("型", value: entry.value.typeName)
            }
            Section {
                if case .boolean = entry.value { Toggle("Boolean", isOn: $boolean).disabled(!editable) }
                else if case .data(let bytes) = entry.value {
                    Text("読み取り専用（\(String(describing: bytes.count)) bytes）")
                    Text(bytes.base64EncodedString()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } else {
                    TextEditor(text: $input).font(.system(.footnote, design: .monospaced)).frame(minHeight: 160)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!editable)
                        .padding(4)
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5), lineWidth: 1).allowsHitTesting(false) }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            } header: { Text("値") } footer: { Text("下書きは詳細エディタの「保存」で書き込みます。") }
            if editable {
                Button("下書きに反映") {
                    do {
                        let value: PropertyListValue
                        if case .boolean = entry.value { value = .boolean(boolean) }
                        else { value = try PlistScalarEditor.parse(input, like: entry.value) }
                        try gestalt.edit(value, entry: entry)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .navigationTitle("値の確認・編集").navigationBarTitleDisplayMode(.inline)
    }
}
