import SwiftUI

struct CacheCleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var usage: AppCacheUsage?
    @State private var loading = true
    @State private var cleaning = false
    @State private var confirmCleanup = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if loading {
                    ProgressView("集計中…")
                } else if let usage {
                    LabeledContent("一時ファイル") {
                        Text(L("\(String(describing: storageSize(usage.temporaryBytes))) / \(String(describing: usage.temporaryItems))件"))
                    }
                    LabeledContent("アプリキャッシュ") {
                        Text(L("\(String(describing: storageSize(usage.cacheBytes))) / \(String(describing: usage.cacheItems))件"))
                    }
                    LabeledContent("合計") {
                        Text(storageSize(usage.totalBytes)).fontWeight(.semibold)
                    }
                } else {
                    Text("使用量を集計できませんでした。").foregroundStyle(.secondary)
                }
            } header: {
                Text("このアプリのキャッシュ")
            } footer: {
                Text("アプリ内のキャッシュを削除します")
            }

            Section {
                Button("キャッシュを削除", role: .destructive) { confirmCleanup = true }
                    .disabled(loading || cleaning || model.busy || (usage?.totalBytes ?? 0) == 0)
                if cleaning { ProgressView("削除中…") }
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle("キャッシュの整理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .alert("キャッシュを削除しますか？", isPresented: $confirmCleanup) {
            Button("削除", role: .destructive) { clean() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このアプリの一時ファイルとキャッシュ（合計\(String(describing: storageSize(usage?.totalBytes ?? 0)))）を削除します。元に戻せません。")
        }
    }

    private func reload() async {
        loading = true
        usage = await model.accessManager.appCacheUsage()
        loading = false
    }

    private func clean() {
        guard !cleaning else { return }
        cleaning = true
        message = nil
        errorMessage = nil
        Task {
            let result = await model.accessManager.clearAppCache()
            await reload()
            cleaning = false
            let freed = storageSize(result.freedBytes)
            if result.failedItems > 0 {
                errorMessage = L("\(String(describing: freed))を削除しましたが、\(String(describing: result.failedItems))件を削除できませんでした。使用中のファイルはアプリを終了してから再度お試しください。")
                model.log(L("キャッシュ削除: \(String(describing: freed))（\(String(describing: result.removedItems))件）、失敗\(String(describing: result.failedItems))件"), error: true)
            } else {
                message = result.removedItems == 0 ? L("削除するキャッシュはありませんでした。") : L("\(String(describing: freed))を削除しました（\(String(describing: result.removedItems))件）。")
                model.log(L("キャッシュ削除: \(String(describing: freed))（\(String(describing: result.removedItems))件）"))
            }
        }
    }
}

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}
