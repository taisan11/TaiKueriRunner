import SwiftUI

struct PathEnumerationView: View {
    let initialPath: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var limit = "500000"
    @State private var results: [String] = []
    @State private var progress = 0.0
    @State private var running = false
    @State private var status = L("未実行")
    @State private var advancedExpanded = false
    @State private var confirmScan = false
    @State private var scanningInodes = false
    @State private var scanTask: Task<Void, Never>?
    private let scanner = PathScanner()

    var body: some View {
        List {
            Section {
                TextField("列挙する親ディレクトリ", text: $path, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.footnote, design: .monospaced))
                    .disabled(running)
            } header: { Text("検索する親フォルダ") }
            Section {
                DisclosureGroup("検索の詳細設定", isExpanded: $advancedExpanded) {
                    LabeledContent("inode上限") {
                        TextField("500000", text: $limit).keyboardType(.numberPad).disabled(running)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("検索するinodeの上限")
                    }
                    Button("一時ファイルから上限の目安を取得") {
                        Task {
                            do { limit = String(min(try await scanner.baselineInode(), 100_000_000)) }
                            catch { model.report(error) }
                        }
                    }.disabled(running)
                    Button("inode検索を使う…", systemImage: "externaldrive.badge.magnifyingglass") {
                        guard validatedMaximum() != nil else { return }
                        confirmScan = true
                    }.disabled(running)
                }
            }
            Section {
                if running {
                    if scanningInodes { ProgressView(value: progress) }
                    else { ProgressView("フォルダを確認中…") }
                    Button("中止", role: .destructive) { scanTask?.cancel() }
                } else {
                    Button("コンテナを検索", systemImage: "magnifyingglass") { listDirectories() }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Section("発見したパス（\(String(describing: results.count))）") {
                if results.isEmpty {
                    Text(running ? L("検索中…") : L("結果はありません"))
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.self) { result in
                    Button {
                        model.browse(result)
                        dismiss()
                    } label: { Text(result).font(.system(.caption, design: .monospaced)) }
                    .contextMenu {
                        Button("パスをコピー") { UIPasteboard.general.string = result }
                        Button("ファイルで開く") { model.browse(result) }
                    }
                }
            }
        }
        .navigationTitle("コンテナを探す").navigationBarTitleDisplayMode(.inline)
        .onAppear { if path.isEmpty { path = initialPath } }
        .onDisappear { scanTask?.cancel() }
        .alert("時間のかかる検索を実行しますか？", isPresented: $confirmScan) {
            Button("inode検索を開始") { startInodeScan() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(String(describing: path))\n\n上限: \(String(describing: limit))\n時間とバッテリーを消費します。すべてのコンテナが見つかるとは限りません。")
        }
    }

    private func listDirectories() {
        guard !running else { return }
        let target = path
        running = true; scanningInodes = false; results = []; status = L("フォルダを確認中…")
        scanTask = Task {
            defer { running = false; scanTask = nil }
            do {
                let entries = try await model.accessManager.list(path: target, showHidden: false)
                try Task.checkCancellation()
                results = entries.filter { $0.isDirectory && !$0.isSymbolicLink }.map(\.path)
                status = L("一覧から\(String(describing: results.count))件を取得しました。")
                model.log(L("コンテナ一覧: \(String(describing: target)) / \(String(describing: results.count))件"))
            } catch is CancellationError {
                status = L("中止しました。")
            } catch {
                guard !Task.isCancelled else { return }
                status = L("一覧を取得できません。アクセス権を確認するか、詳細設定のinode検索を使用してください。")
                advancedExpanded = true
                model.log(L("コンテナ一覧を取得できません: \(String(describing: target)) / \(String(describing: error.localizedDescription))"), error: true)
            }
        }
    }

    private func validatedMaximum() -> UInt64? {
        guard let maximum = UInt64(limit), maximum > 0, maximum <= 100_000_000 else {
            model.report(RunnerError(localized: "inode上限は1〜100,000,000で指定してください。")); return nil
        }
        return maximum
    }

    private func startInodeScan() {
        guard !running, let maximum = validatedMaximum() else { return }
        let target = path
        running = true; scanningInodes = true; results = []; progress = 0; status = L("inode検索中…")
        scanTask = Task {
            defer { running = false; scanTask = nil }
            do {
                results = try await scanner.scan(path: target, maximum: maximum) { value, paths in
                    await MainActor.run { progress = value; results = paths }
                }
                status = L("完了: \(String(describing: results.count))件（inode \(String(describing: maximum))まで）")
                model.log(L("pathleak: \(String(describing: target)) / \(String(describing: status))"))
            } catch is CancellationError {
                status = L("中止しました。\(String(describing: results.count))件の途中結果。")
                model.log(L("pathleakを中止: \(String(describing: target))"))
            } catch { status = error.localizedDescription; model.report(error) }
        }
    }
}
