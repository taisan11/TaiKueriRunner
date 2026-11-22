import SwiftUI

struct SQLiteFileView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var staged: StagedDocumentPreview?
    @State private var document: SQLiteDocument?
    @State private var schema: SQLiteSchema?
    @State private var selectedTable = ""
    @State private var offset = 0
    @State private var page: SQLitePage?
    @State private var loading = true
    @State private var pageLoading = false
    @State private var errorMessage: String?
    @State private var pageError: String?
    @State private var shareEntry: FileEntry?
    @State private var lifecycle = UUID()
    @State private var retry = UUID()
    @State private var reload = UUID()

    private struct PageRequest: Hashable {
        let directory: URL?
        let table: String
        let offset: Int
        let retry: UUID
    }

    private var request: PageRequest {
        PageRequest(directory: staged?.directory, table: selectedTable, offset: offset, retry: retry)
    }

    private var table: SQLiteTable? { schema?.tables.first { $0.name == selectedTable } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("SQLite · 読み取り専用", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("ファイル情報") {
                    Text(entry.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("元のアプリを停止してから開いてください。長い値は省略して表示します。")
                        .font(.caption).foregroundStyle(.secondary)
                }.font(.caption)
            }.padding().background(.bar)

            if loading {
                ProgressView("SQLiteを読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("SQLiteを表示できません", systemImage: "externaldrive.badge.exclamationmark", description: Text(errorMessage))
            } else if let schema, !schema.tables.isEmpty {
                tableControls(schema: schema)
                Divider()
                if pageLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pageError {
                    ContentUnavailableView {
                        Label("データを表示できません", systemImage: "tablecells")
                    } description: { Text(pageError) } actions: {
                        Button("再試行") { retry = UUID() }
                    }
                } else if let page {
                    if page.rows.isEmpty {
                        ContentUnavailableView("行がありません", systemImage: "tablecells")
                    } else {
                        dataGrid(page: page).id(request)
                    }
                } else { Spacer() }
                pageControls
            } else {
                ContentUnavailableView("テーブルがありません", systemImage: "tablecells")
            }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("DBを読み直す", systemImage: "arrow.clockwise") {
                        closeSnapshot()
                        reload = UUID()
                    }.disabled(loading)
                    NavigationLink { HexFileView(entry: entry) } label: { Label("16進数で表示", systemImage: "number") }
                    FileShareButton(entry: entry, selection: $shareEntry)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("SQLiteの表示方法")
            }
        }
        .sheet(item: $shareEntry) { FileShareView(entry: $0) }
        .task(id: reload) { await loadSnapshot() }
        .task(id: request) { await loadPage() }
        .onDisappear { closeSnapshot() }
    }

    private func tableControls(schema: SQLiteSchema) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("テーブル・ビュー", selection: Binding(get: { selectedTable }, set: {
                page = nil
                offset = 0
                selectedTable = $0
            })) {
                ForEach(schema.tables) { table in
                    Text(table.name + (table.type == "view" ? L("（ビュー）") : "")).tag(table.name)
                }
            }
            if schema.truncated { Text("一覧は先頭512件までです。").font(.caption).foregroundStyle(.secondary) }
            if let table {
                DisclosureGroup("スキーマ（CREATE文）") {
                    ScrollView([.horizontal, .vertical]) {
                        Text(table.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.vertical, 4)
                    }.frame(maxHeight: 140)
                }.font(.caption)
            }
        }.padding()
    }

    private func dataGrid(page: SQLitePage) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(page.rows.indices, id: \.self) { row in
                        HStack(alignment: .top, spacing: 0) {
                            cell(String(offset + row + 1), width: 72)
                            ForEach(page.columns.indices, id: \.self) { column in
                                cell(page.rows[row][column])
                            }
                        }
                        .background(row.isMultiple(of: 2) ? Color.secondary.opacity(0.06) : Color.clear)
                        Divider()
                    }
                } header: {
                    HStack(alignment: .top, spacing: 0) {
                        cell(L("行"), width: 72)
                        ForEach(page.columns.indices, id: \.self) { cell(page.columns[$0]) }
                    }.fontWeight(.semibold).background(.bar)
                }
            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func cell(_ text: String, width: CGFloat = 180) -> some View {
        Text(text).lineLimit(6).frame(width: width, alignment: .leading).padding(8)
            .accessibilityLabel(text)
    }

    private var pageControls: some View {
        HStack {
            Button("前へ", systemImage: "chevron.left") { page = nil; offset = max(0, offset - SQLiteDocument.pageSize) }
                .disabled(pageLoading || offset == 0)
            Spacer()
            Text(page.map { $0.rows.isEmpty ? L("0行") : L("\(String(describing: offset + 1))–\(String(describing: offset + $0.rows.count))行") } ?? "")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("次へ", systemImage: "chevron.right") { page = nil; offset += SQLiteDocument.pageSize }
                .disabled(pageLoading || page?.hasMore != true || offset >= SQLiteDocument.maximumOffset)
        }.padding().background(.bar)
    }

    private func loadSnapshot() async {
        let generation = lifecycle
        loading = true
        errorMessage = nil
        do {
            let preview = try await model.accessManager.stageSQLitePreview(path: entry.path)
            do {
                let database = SQLiteDocument(url: preview.url)
                let result = try await database.schema()
                try Task.checkCancellation()
                guard lifecycle == generation else { throw CancellationError() }
                schema = result
                selectedTable = result.tables.first?.name ?? ""
                offset = 0
                staged = preview
                document = database
            } catch {
                await model.accessManager.closeDocumentPreview(preview)
                throw error
            }
        } catch is CancellationError {} catch {
            if lifecycle == generation, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        if lifecycle == generation { loading = false }
    }

    private func loadPage() async {
        guard let document, let table else { return }
        let current = request
        pageLoading = true
        pageError = nil
        page = nil
        do {
            let result = try await document.page(table: table, offset: current.offset)
            try Task.checkCancellation()
            if request == current { page = result }
        } catch is CancellationError {} catch {
            if request == current, !Task.isCancelled { pageError = error.localizedDescription }
        }
        if request == current { pageLoading = false }
    }

    private func closeSnapshot() {
        let preview = staged
        staged = nil
        document = nil
        schema = nil
        page = nil
        pageError = nil
        pageLoading = false
        loading = true
        lifecycle = UUID()
        if let preview { Task { await model.accessManager.closeDocumentPreview(preview) } }
    }
}
