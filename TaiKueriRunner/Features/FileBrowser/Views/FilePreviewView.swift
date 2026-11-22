import SwiftUI

struct FilePreviewView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var original = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var message: String?
    @State private var writeRequest: FileWriteRequest?
    @State private var shareEntry: FileEntry?
    @State private var pendingText = ""
    @State private var confirmClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    if let modified = entry.modified { Text(modified, style: .date) }
                    Spacer()
                    Text("UTF-8")
                }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("ファイルの場所") {
                    Text(entry.path).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(.top, 4)
                }.font(.caption).tint(.secondary)
            }.padding().background(.bar)
            if let message {
                ContentUnavailableView("テキスト表示できません", systemImage: "doc.questionmark", description: Text(message))
                NavigationLink { HexFileView(entry: entry) } label: { Label("16進数で表示", systemImage: "number") }.padding()
                NavigationLink { SQLiteFileView(entry: entry) } label: { Label("SQLiteで表示", systemImage: "tablecells") }.padding(.bottom)
            } else if loaded {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .disabled(writeRequest != nil)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(text != original || writeRequest != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { if text != original { confirmClose = true } else { dismiss() } }.disabled(writeRequest != nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    NavigationLink { SQLiteFileView(entry: entry) } label: { Label("SQLiteで表示", systemImage: "tablecells") }
                    NavigationLink { HexFileView(entry: entry) } label: { Label("16進数で表示", systemImage: "number") }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("表示方法")
                FileShareButton(entry: entry, compact: true, selection: $shareEntry)
                if loaded {
                    Button("保存") {
                        pendingText = text
                        model.run(L("保存の確認を準備")) {
                            writeRequest = try await model.accessManager.prepareWrite(.saveText(path: entry.path, text: pendingText, original: original))
                        }
                    }.disabled(text == original || writeRequest != nil || model.busy)
                }
            }
        }
        .task {
            do { text = try await model.accessManager.readText(path: entry.path); original = text; loaded = true }
            catch { message = error.localizedDescription }
        }
        .fileWriteConfirmation(request: $writeRequest) { original = pendingText }
        .sheet(item: $shareEntry) { FileShareView(entry: $0) }
        .alert("変更を破棄しますか？", isPresented: $confirmClose) {
            Button("破棄して閉じる", role: .destructive) { dismiss() }
            Button("編集に戻る", role: .cancel) {}
        }
    }
}
