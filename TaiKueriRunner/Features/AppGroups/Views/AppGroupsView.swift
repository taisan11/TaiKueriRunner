import SwiftUI

struct AppGroupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    private var scan: AppGroupScanModel { model.appGroupScan }
    @State private var search = ""
    @State private var visible = false
    @State private var paused = false
    @State private var reloadID = UUID()
    @State private var databaseStatus: String?
    @State private var refreshCatalog = false

    private struct ScanRequest: Equatable {
        let active: Bool
        let reload: UUID
    }
    private var scanRequest: ScanRequest {
        ScanRequest(active: visible && scenePhase == .active && model.selectedTab == .applications && !model.busy && !paused,
                    reload: reloadID)
    }
    private var groups: [AppGroupContainer] {
        (scan.snapshot?.containers ?? []).filter { $0.matches(search) }
    }
    private var isSearching: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            Section("検索") {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("グループID・UUID", text: $search)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityLabel("App Groupsを検索")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("検索をクリア")
                    }
                }
            }
            Section {
                Label("App Groupsの共有フォルダ", systemImage: "folder.badge.person.crop")
                Text("共有フォルダのIDと読み取り可否を調べます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if scan.loading {
                Section {
                    HStack {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text(databaseStatus ?? scan.snapshot?.phase ?? L("準備中…"))
                            if let snapshot = scan.snapshot {
                                Text("\(String(describing: snapshot.scannedCount)) / \(String(describing: snapshot.candidateCount))フォルダ")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("中止") { paused = true; scan.cancel() }
                }
            }
            if scan.interrupted || paused {
                Section {
                    Text("探索を中止しました。取得済みの項目を表示しています。")
                    Button("再開") { reload() }
                }
            }
            if let issue = scan.snapshot?.rootIssue {
                Section("一覧取得の制限") {
                    Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if let issue = scan.snapshot?.catalogIssue {
                Section("アプリDBの制限") {
                    Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Text("DBに記録された候補だけを確認しています。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = scan.error {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("再試行", systemImage: "arrow.clockwise") { reload() }
                }
            }
            Section("App Groups · \(String(describing: groups.count))件") {
                ForEach(groups) { group in
                    NavigationLink { AppGroupDetailView(group: group) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).lineLimit(2)
                            Text(group.uuid).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text(group.canOpen ? L("読み取り確認済み") : L("読み取り未確認"))
                                .font(.caption).foregroundStyle(group.canOpen ? Color.secondary : Color.orange)
                        }.padding(.vertical, 2)
                    }
                }
                if groups.isEmpty && !scan.loading {
                    ContentUnavailableView(
                        isSearching ? L("一致するApp Groupはありません") : L("共有フォルダを確認できませんでした"),
                        systemImage: "folder.badge.questionmark",
                        description: Text(isSearching ? L("グループID・UUIDで検索してください。") : L("読み取りの制限を確認し、一覧を更新してください。未検出の共有フォルダが残っている場合があります。")))
                }
            }
            if let snapshot = scan.snapshot {
                Section {
                    Text(scan.complete ? L("探索完了（確認できた範囲）") : L("読み取り途中の結果"))
                    Text("未存在 \(String(describing: snapshot.missingCount))件 / リンク・通常フォルダ以外 \(String(describing: snapshot.skippedCount))件を除外")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("App Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("更新", systemImage: "arrow.clockwise") { reload() }.disabled(model.busy) }
        .refreshable { reload() }
        .onAppear { visible = true }
        .onDisappear { visible = false; scan.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { scan.cancel() } }
        .task(id: scanRequest, priority: .utility) {
            guard !Task.isCancelled, scanRequest.active else { return }
            // Reuse an existing result (including a partial list left by 中止)
            // until the user explicitly refreshes or retries. A failed scan is
            // retried from its own button instead of on every appearance.
            guard (scan.snapshot == nil && scan.error == nil) || refreshCatalog else { return }
            let force = refreshCatalog
            refreshCatalog = false
            databaseStatus = L("アプリDBを読み込み中…")
            await scan.load(forceRefresh: force) { progress in
                try await model.scanAppGroups(forceRefresh: force, progress: progress)
            }
            databaseStatus = nil
        }
    }

    private func reload() { paused = false; refreshCatalog = true; reloadID = UUID() }
}

private struct AppGroupDetailView: View {
    let group: AppGroupContainer
    @Environment(AppModel.self) private var model
    @State private var exportContainer: ExportTarget?

    private struct ExportTarget: Identifiable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        Form {
            Section("グループID") {
                Text(group.title).textSelection(.enabled)
                if let source = group.identificationSource { Text(source).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                Text(group.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("ファイルビューアーで開く", systemImage: "folder") { model.browse(group.path) }
                    .disabled(!group.canOpen || model.busy)
                Button("パスをコピー", systemImage: "doc.on.doc") { UIPasteboard.general.string = group.path }
                Button("データをエクスポート（ZIP）", systemImage: "square.and.arrow.up") {
                    exportContainer = ExportTarget(path: group.path)
                }
                .disabled(!group.canOpen || model.busy)
            } header: {
                Text("共有フォルダ")
            } footer: {
                Text("共有フォルダのデータをコピーしてZIPで共有・ファイルに保存できます（最大2 GiB・50,000項目）。権限で読めない項目は省略し、ZIP内のExportReport.jsonに記録します。共有データの変更は複数アプリへ影響するため、利用するアプリを終了してから実行してください。ZIPは暗号化されず、個人情報を含む場合があります。")
            }
            if !group.issues.isEmpty {
                Section("読み取りの詳細") {
                    Text(group.issues.joined(separator: "\n\n")).font(.caption).textSelection(.enabled)
                }
            }
            Section {
                Text("探索とエクスポートは元データを変更しません。ファイルビューアーでの変更・削除には通常の確認とバックアップが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("App Group")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportContainer) { container in
            AppGroupDataExportView(group: group, path: container.path)
        }
    }
}
