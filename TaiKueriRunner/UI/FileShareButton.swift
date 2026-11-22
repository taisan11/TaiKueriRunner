import SwiftUI

// Sharing can outlive a sandbox lease. Hand the system a private, read-only
// snapshot instead of an inaccessible original URL after automatic release.
struct FileShareButton: View {
    let entry: FileEntry
    var compact = false
    @Binding var selection: FileEntry?

    var body: some View {
        Button { selection = entry } label: {
            if compact { Image(systemName: "square.and.arrow.up") }
            else { Label("コピーを共有 / 別のアプリで開く", systemImage: "square.and.arrow.up") }
        }
        .accessibilityLabel("ファイルのコピーを共有")
        .disabled(entry.isDirectory || entry.isSymbolicLink)
    }
}

struct FileShareView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var staged: StagedDocumentPreview?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let staged { FileShareController(url: staged.url) { dismiss() } }
            else {
                NavigationStack {
                    Group {
                        if let errorMessage { ContentUnavailableView("共有用コピーを作成できません", systemImage: "doc.questionmark", description: Text(errorMessage)) }
                        else { ProgressView("共有用コピーを準備中…（最大256 MiB）") }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
                }
            }
        }
        .task {
            do {
                let result = try await model.accessManager.stageDocumentPreview(path: entry.path, maximumBytes: Int(FileBackupStore.maximumBytes))
                guard !Task.isCancelled else { await model.accessManager.closeDocumentPreview(result); return }
                staged = result
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .onDisappear { cleanup() }
    }

    private func cleanup() {
        if let staged { Task { await model.accessManager.closeDocumentPreview(staged) } }
        staged = nil
    }
}

struct FileShareController: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
