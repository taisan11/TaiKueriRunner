import SwiftUI

struct ApplicationDetailView: View {
    let application: CatalogApplication
    let snapshot: ApplicationCatalogSnapshot
    @Environment(AppModel.self) private var model
    @State private var destinationPath: String?
    @State private var exportContainer: ExportTarget?

    private struct ExportTarget: Identifiable {
        let path: String
        var id: String { path }
    }

    private var relatedExtensions: [CatalogApplication] {
        guard application.kind == .application else { return [] }
        return snapshot.catalog.applications.filter { $0.kind == .appExtension && $0.bundleID.hasPrefix(application.bundleID + ".") }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ApplicationTile(application: application)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(application.name).font(.headline)
                        Text(application.kind.title).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                Text(application.bundleID).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                LabeledContent("提供元", value: application.isApple ? L("Apple（Bundle IDによる分類）") : L("ユーザー / その他"))
            }
            Section {
                ForEach(application.containerPaths, id: \.self) { path in
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .contextMenu {
                            Button("パスをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                        }
                    // Automatic Form-row buttons can invoke every action in a
                    // shared row. Keep actions on separate rows with explicit styles.
                    Button("ファイルを開く", systemImage: "folder") { open(path) }
                        .buttonStyle(.borderless)
                    Button("データをエクスポート（ZIP）", systemImage: "square.and.arrow.up") {
                        exportContainer = ExportTarget(path: path)
                    }
                    .buttonStyle(.borderless)
                }
            } header: { Text("データコンテナ") } footer: {
                Text("対象アプリを終了してから実行してください。tmpや読めない項目などは省略した上でそのコンテナのファイルを出力します。")
            }
            if !relatedExtensions.isEmpty {
                Section {
                    ForEach(relatedExtensions) { item in
                        NavigationLink { ApplicationDetailView(application: item, snapshot: snapshot) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                Text(item.bundleID).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("同じBundle ID接頭辞の拡張機能") } footer: {
                    Text("ID接頭辞で分類した表示です。共有コンテナの所有関係を示すものではありません。")
                }
            }
            if let bundlePath = application.bundlePath {
                Section("バンドルの場所") {
                    Text(bundlePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(application.name).navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .toolbar {
            Menu {
                Button("Bundle IDをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = application.bundleID }
                if let path = application.containerPaths.first {
                    Button("ファイルタブで開く", systemImage: "folder") { model.browse(path) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("アプリ情報の操作")
        }
        .navigationDestination(item: $destinationPath) { path in
            ApplicationContainerView(initialPath: path, title: application.name)
        }
        .sheet(item: $exportContainer) { container in
            ApplicationDataExportView(application: application, path: container.path)
        }
    }

    private func open(_ path: String) {
        destinationPath = path
    }
}

private struct ApplicationContainerView: View {
    let title: String
    @State private var path: String

    init(initialPath: String, title: String) {
        self.title = title
        self._path = State(initialValue: initialPath)
    }

    var body: some View {
        FileBrowserView(path: $path, title: title).navigationBarTitleDisplayMode(.inline)
    }
}
