import SwiftUI

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var records: [FileBackupRecord] = []
    @State private var search: String
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var unreadableCount = 0
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var notice: String?

    init(initialSearch: String = "") { _search = State(initialValue: initialSearch) }

    private var visible: [FileBackupRecord] {
        records.filter { search.isEmpty || $0.targetPath.localizedStandardContains(search) || $0.manifest.operation.localizedStandardContains(search) }
    }
    private var totalBytes: Int64 { records.reduce(0) { $0 + $1.size } }
    private var selectedBytes: Int64 { records.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }
    private var allVisibleSelected: Bool { !visible.isEmpty && Set(visible.map(\.id)).isSubset(of: selection) }

    var body: some View {
        List {
            Section {
                Text("復元前の状態もバックアップします。元データの復元と、作成した項目の取り消しを操作別に案内します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("保存件数", value: L("\(String(describing: records.count))件"))
                LabeledContent("データ量", value: backupSize(totalBytes))
            } footer: {
                Text(selecting ? L("\(String(describing: selection.count))件を選択中。削除しても元のファイルは変更されません。") : L("「選択」から複数件をまとめて削除できます。"))
            }
            if let notice {
                Section { Text(notice).foregroundStyle(.secondary) }
            }
            if loading { ProgressView("バックアップを読み込み中…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if !loading && visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? L("バックアップはまだありません") : L("一致するバックアップはありません"), systemImage: "externaldrive.badge.timemachine")
            }
            ForEach(visible) { record in
                if selecting {
                    Button { toggle(record.id) } label: {
                        BackupRow(record: record, selected: selection.contains(record.id))
                    }
                    .buttonStyle(.plain)
                    .disabled(deleting)
                } else {
                    NavigationLink { BackupDetailView(record: record) } label: {
                        BackupRow(record: record, selected: nil)
                    }
                }
            }
            if unreadableCount > 0 {
                Text("\(String(describing: unreadableCount))件の不完全または不正な記録を除外しました。ファイルから確認できます。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Section {
                Button("バックアップフォルダをファイルで開く", systemImage: "folder") { model.browse(model.accessManager.backupRoot.path) }
            } footer: {
                Text("自動削除はしません。削除する場合は「選択」から対象を選んでください。アプリを削除するとバックアップも失われます。重要なデータは外部にも保存してください。")
            }
        }
        .navigationTitle("バックアップと復元")
        .searchable(text: $search, prompt: "元のパス・操作で検索")
        .task(id: model.browserRevision) { await reload() }
        .refreshable { await reload() }
        .onChange(of: search) { _, _ in
            if selecting { selection.formIntersection(Set(visible.map(\.id))) }
        }
        .toolbar {
            if selecting {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("一括削除", role: .destructive) {
                        selection = Set(visible.map(\.id))
                        confirmDelete = true
                    }
                    .disabled(visible.isEmpty || deleting || model.busy)
                    Button("完了") { endSelection() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(allVisibleSelected ? L("選択解除") : L("全選択")) { toggleAllVisible() }
                        .disabled(visible.isEmpty || deleting)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("選択") { selecting = true; selection.removeAll() }
                        .disabled(records.isEmpty)
                }
            }
        }
        .alert("バックアップを削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { deleteSelected() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択した\(String(describing: selection.count))件（\(String(describing: backupSize(selectedBytes)))）を削除します。元に戻せません。元のファイルは変更しません。")
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let listing = try await model.accessManager.backups()
            try Task.checkCancellation()
            records = listing.records
            unreadableCount = listing.unreadableCount
            errorMessage = nil
            selection.formIntersection(Set(records.map(\.id)))
            if records.isEmpty { endSelection() }
        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    private func deleteSelected() {
        let ids = selection.sorted()
        guard !ids.isEmpty, !deleting else { return }
        deleting = true
        errorMessage = nil
        notice = nil
        Task {
            do {
                let result = try await model.accessManager.deleteBackups(ids: ids)
                deleting = false
                endSelection()
                await reload()
                let freed = backupSize(result.freedBytes)
                if result.failed.isEmpty {
                    notice = L("\(String(describing: result.removed.count))件（\(String(describing: freed))）を削除しました。")
                    model.log(L("バックアップを\(String(describing: result.removed.count))件（\(String(describing: freed))）削除しました。"))
                } else {
                    notice = L("\(String(describing: result.removed.count))件（\(String(describing: freed))）を削除しました。\(String(describing: result.failed.count))件は削除できませんでした。")
                    model.log(L("バックアップ削除: \(String(describing: result.removed.count))件成功、\(String(describing: result.failed.count))件失敗"), error: true)
                }
            } catch {
                deleting = false
                errorMessage = error.localizedDescription
                model.log(L("バックアップ削除失敗: \(String(describing: error.localizedDescription))"), error: true)
            }
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleAllVisible() {
        let ids = Set(visible.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    private func endSelection() {
        selecting = false
        selection.removeAll()
    }
}

private struct BackupRow: View {
    let record: FileBackupRecord
    let selected: Bool?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(record.manifest.wallpaper.map { $0.isRefresh ? L("壁紙の表示を更新") + L(" · 表示設定") : $0.title } ??
                     (record.targetPath as NSString).lastPathComponent).font(.headline)
                Text(LKey(record.manifest.operation) + " · " + record.status).font(.caption).foregroundStyle(.secondary)
                Text(record.manifest.created, format: .dateTime.year().month().day().hour().minute().second()).font(.caption)
                Text(record.targetPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct BackupDetailView: View {
    let record: FileBackupRecord
    @Environment(AppModel.self) private var model
    @State private var request: FileWriteRequest?

    var body: some View {
        Form {
            Section("バックアップ") {
                LabeledContent("操作", value: LKey(record.manifest.operation))
                LabeledContent("状態", value: record.status)
                LabeledContent("日時") { Text(record.manifest.created, format: .dateTime) }
                LabeledContent("データ量", value: backupSize(record.size))
                Text(record.targetPath).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                if record.manifest.version == 1 { Text("旧形式：内容ハッシュはありません。復元前に元データを確認してください。").font(.footnote).foregroundStyle(.orange) }
            }
            Section("復元方法") {
                Text(record.restorationNote)
                if let reason = restorationError { Text(reason).font(.footnote).foregroundStyle(.orange) }
                Button("このバックアップを復元…", systemImage: "arrow.uturn.backward") {
                    model.run(L("復元の確認を準備")) { request = try await model.accessManager.prepareWrite(.restoreBackup(id: record.id)) }
                }.disabled(restorationError != nil || model.busy)
            }
            Section {
                Button("ファイルで確認・共有", systemImage: "folder") { model.browse(record.directory.path) }
                Text(record.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle("復元の詳細").navigationBarTitleDisplayMode(.inline)
        .fileWriteConfirmation(request: $request)
    }

    private var restorationError: String? {
        do { _ = try record.restoration(); return nil }
        catch { return error.localizedDescription }
    }
}

private func backupSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
