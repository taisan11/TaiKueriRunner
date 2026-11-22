import SwiftUI

struct AppGroupDataExportView: View {
    let group: AppGroupContainer
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var staged: ApplicationDataExport.StagedExport?
    @State private var confirmedPartial = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let staged, !staged.report.isPartial || confirmedPartial {
                FileShareController(url: staged.document.url) { dismiss() }
            } else if let staged {
                NavigationStack {
                    Form {
                        Section("一部を省略したエクスポート") {
                            Text("権限で読み取れない項目を\(String(describing: staged.report.skippedItems.count))件省略しました。完全なエクスポートではありません。")
                                .foregroundStyle(.orange)
                            LabeledContent("コピー済みファイル", value: L("\(String(describing: staged.report.copiedFileCount))件"))
                            Text("省略したパスと理由はZIP直下のExportReport.jsonで確認できます。フォルダを省略した場合、その内部も含まれません。")
                        }
                        Button("省略ありで共有・保存") { confirmedPartial = true }
                    }
                    .navigationTitle(group.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
                }
            }
            else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if let errorMessage {
                            ContentUnavailableView {
                                Label("エクスポートできません", systemImage: "doc.questionmark")
                            } description: {
                                Text(errorMessage).textSelection(.enabled)
                            }
                        } else {
                            ProgressView("データをコピーしてZIPを作成中…")
                            Text("最大2 GiB・50,000項目。読めない項目はレポートに記録して省略します。元データは変更しません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .navigationTitle(group.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
                }
            }
        }
        .task {
            do {
                let result = try await model.accessManager.stageAppGroupDataExport(group: group, path: path)
                guard !Task.isCancelled else { await model.accessManager.closeDocumentPreview(result.document); return }
                staged = result
                model.log(L("\(String(describing: group.title))の共有データを共有用ZIPへエクスポートしました（省略\(String(describing: result.report.skippedItems.count))件）。"))
            } catch is CancellationError {} catch {
                errorMessage = error.localizedDescription
                model.log(L("App Groupデータのエクスポート失敗: \(String(describing: error.localizedDescription))"), error: true)
            }
        }
        .onDisappear {
            if let staged { Task { await model.accessManager.closeDocumentPreview(staged.document) } }
            staged = nil
        }
    }
}
