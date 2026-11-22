import SwiftUI

/// Top-layer entry point for LINE data. LINE keeps the databases the viewer
/// needs in its shared App Group, so the screen resolves that container
/// automatically and shows the chat list directly instead of asking which
/// source to open.
struct LINEHubView: View {
    @Environment(AppModel.self) private var model
    @State private var group: AppGroupContainer?
    @State private var started = false
    @State private var failure: String?

    private var scan: AppGroupScanModel { model.appGroupScan }

    // LINE's shared container. It is preferred over any other linecorp group,
    // and the remaining candidates keep older layouts working.
    private static let lineGroupID = "group.com.linecorp.line"

    private var candidates: [AppGroupContainer] {
        let readable = (scan.snapshot?.containers ?? []).filter(\.canOpen)
        let exact = readable.filter { $0.groupID == Self.lineGroupID }
        if !exact.isEmpty { return exact }
        return readable.filter { $0.groupID?.hasPrefix("group.com.linecorp") == true }
    }

    var body: some View {
        Group {
            if let group {
                LINEDataDeviceView(group: group)
            } else if let failure {
                ContentUnavailableView {
                    Label("LINEの共有フォルダを開けません", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(failure)
                } actions: {
                    Button("再試行", systemImage: "arrow.clockwise") { resolve(force: true) }
                        .disabled(model.busy)
                }
            } else {
                ProgressView {
                    VStack(spacing: 6) {
                        Text("LINEデータを準備中…")
                        Text(scan.snapshot?.phase ?? L("LINEの共有フォルダを確認しています…"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let snapshot = scan.snapshot {
                            Text("\(String(describing: snapshot.scannedCount)) / \(String(describing: snapshot.candidateCount))フォルダ")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("LINEビューア")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard !started else { return }
            started = true
            resolve(force: false)
        }
    }

    private func resolve(force: Bool) {
        failure = nil
        group = nil
        Task {
            guard model.canAcquireAccess else {
                failure = L("共有フォルダの探索には実行許可範囲のOSと有効なApp Groupが必要です。")
                return
            }
            await scan.load(forceRefresh: force) { progress in
                try await model.scanAppGroups(forceRefresh: force, progress: progress)
            }
            if let error = scan.error {
                failure = error
                return
            }
            guard let selected = candidates.first else {
                failure = L("LINEの共有フォルダ（\(String(describing: Self.lineGroupID))）を確認できませんでした。LINEを一度起動してから再試行してください。")
                return
            }
            group = selected
        }
    }
}
