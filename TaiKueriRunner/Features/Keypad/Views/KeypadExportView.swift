import SwiftUI
import UIKit

struct KeypadExportView: View {
    let snapshot: KeypadLibrarySnapshot
    var key: KeypadKey?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var staged: StagedDocumentPreview?
    @State private var showSave = false
    @State private var working = false
    @State private var message: String?
    @State private var error: String?
    @State private var generation = UUID()
    @State private var task: Task<Void, Never>?

    private var files: [KeypadCacheFile] {
        snapshot.files.filter { key == nil || $0.name.key == key }.sorted { $0.path < $1.path }
    }

    var body: some View {
        List {
            Section {
                Text("電話 · \(String(describing: files.count))枚")
                Text("端末から読み取った既存PNGを、縮小・切り抜きせず保存します。編集中の画像やプレビューは含めません。適用済みの場合は、現在の端末画像が保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("一覧の画像をまとめて保存（ZIP）", systemImage: "square.and.arrow.down") { prepare(files, archive: true) }
                    .disabled(files.isEmpty || working || staged != nil || model.busy)
            }
            if working {
                Section {
                    ProgressView("元画像のコピーを準備中…")
                    Button("準備を中止", role: .cancel) { cancelPreparation() }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Section("個別にPNGを保存") {
                if files.isEmpty { Text("保存できる既存画像がありません。端末の画像を再読み込みしてください。") }
                ForEach(files, id: \.path) { file in
                    Button { prepare([file], archive: false) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name.leaf).font(.subheadline).foregroundStyle(.primary)
                            Text("\(URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent) · \(file.width)×\(file.height) px")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(working || staged != nil || model.busy)
                }
            }
        }
        .navigationTitle(key.map { L("キー\(String(describing: $0.rawValue))の既存画像") } ?? L("既存画像を保存"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        .sheet(isPresented: $showSave, onDismiss: cleanup) {
            if let staged {
                KeypadSaveController(url: staged.url) { saved in
                    message = saved ? L("ファイルに保存しました。") : L("保存をキャンセルしました。")
                    showSave = false
                }
                .interactiveDismissDisabled()
            }
        }
        .onDisappear {
            cancelPreparation()
            // Keep the copy available while the document provider owns the picker.
            if !showSave { cleanup() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { cancelPreparation() }
        }
    }

    private func prepare(_ entries: [KeypadCacheFile], archive: Bool) {
        guard !working, staged == nil else { return }
        let token = UUID()
        generation = token; working = true; error = nil; message = nil
        task = Task(priority: .utility) {
            defer { if generation == token { working = false; task = nil } }
            do {
                let result = try await model.keypadService.stageExport(entries, archive: archive)
                guard !Task.isCancelled, generation == token else { await model.keypadService.closeExport(result); return }
                staged = result
                showSave = true
            } catch is CancellationError {}
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }

    private func cancelPreparation() {
        generation = UUID(); task?.cancel(); task = nil; working = false
    }

    private func cleanup() {
        if let staged { Task { await model.keypadService.closeExport(staged) } }
        staged = nil
    }
}

// Export a private copy through the system Files picker; never give it a
// privileged cache URL or write to a user-selected destination ourselves.
private struct KeypadSaveController: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Bool) -> Void
        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete(false) }
    }
}
