import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct FileInspectorView: View {
    let entry: FileEntry
    var body: some View {
        if SQLiteSnapshot.extensions.contains(entry.url.pathExtension.lowercased()) {
            SQLiteFileView(entry: entry)
        } else if entry.url.pathExtension.lowercased() == "plist" {
            PropertyListFileView(entry: entry)
        } else if let type = UTType(filenameExtension: entry.url.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audio) || type.conforms(to: .movie) {
            SystemDocumentFileView(entry: entry)
        } else {
            FilePreviewView(entry: entry)
        }
    }
}

private struct PropertyListFileView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preview: PropertyListDocumentPreview?
    @State private var errorMessage: String?
    @State private var showXML = false
    @State private var shareEntry: FileEntry?

    var body: some View {
        VStack(spacing: 0) {
            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Label(preview.format + L(" · 読み取り専用"), systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Picker("表示", selection: $showXML) {
                        Text("構造").tag(false)
                        Text("XML").tag(true)
                    }.pickerStyle(.segmented)
                }.padding().background(.bar)
                if showXML {
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                } else {
                    List {
                        OutlineGroup([preview.root], children: \.children) { node in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(node.key).font(.system(.subheadline, design: .monospaced)).bold()
                                    Spacer()
                                    Text(node.type).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(node.value.isEmpty ? L("（空文字列）") : node.value)
                                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            }.padding(.vertical, 2)
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Plistを表示できません", systemImage: "doc.questionmark", description: Text(errorMessage))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink { FilePreviewView(entry: entry) } label: { Label("UTF-8テキストとして開く", systemImage: "doc.text") }
                    NavigationLink { HexFileView(entry: entry) } label: { Label("16進数で表示", systemImage: "number") }
                    FileShareButton(entry: entry, selection: $shareEntry)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Plistの表示方法")
            }
        }
        .sheet(item: $shareEntry) { FileShareView(entry: $0) }
        .task {
            do {
                let result = try await model.accessManager.readPropertyListPreview(path: entry.path)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
}

struct HexFileView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @State private var preview: HexDocumentPreview?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let preview {
                Text("読み取り専用 · \(String(describing: preview.shownBytes.formatted())) / \(String(describing: preview.totalBytes.formatted())) bytes（最大64 KiB）")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding().background(.bar)
                ScrollView([.horizontal, .vertical]) {
                    Text(preview.text.isEmpty ? L("空のファイルです。") : preview.text)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else if let errorMessage {
                ContentUnavailableView("ファイルを表示できません", systemImage: "doc.questionmark", description: Text(errorMessage))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let result = try await model.accessManager.readHexPreview(path: entry.path)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct SystemDocumentFileView: View {
    let entry: FileEntry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var staged: StagedDocumentPreview?
    @State private var shareEntry: FileEntry?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let staged {
                Label("読み取り専用", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 8)
                ReadOnlyQuickLook(url: staged.url)
            } else if let errorMessage {
                ContentUnavailableView("プレビューできません", systemImage: "doc.questionmark", description: Text(errorMessage))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { FileShareButton(entry: entry, compact: true, selection: $shareEntry) }
        }
        .sheet(item: $shareEntry) { FileShareView(entry: $0) }
        .task {
            do {
                let result = try await model.accessManager.stageDocumentPreview(path: entry.path)
                guard !Task.isCancelled else { await model.accessManager.closeDocumentPreview(result); return }
                staged = result
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
            if let staged { Task { await model.accessManager.closeDocumentPreview(staged) } }
        }
    }
}

private struct ReadOnlyQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
        nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }
}
