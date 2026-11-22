import SwiftUI

struct UtilitiesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                        .frame(width: 44, height: 44)
                        .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TaiKueriRunner").font(.headline)
                        Text("端末のカスタマイズツール").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("バージョン", value: appVersion)
                NavigationLink { AboutView() } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            } header: { Text("アプリの情報") }
            Section("ストレージ") {
                NavigationLink { CacheCleanupView() } label: { Label("キャッシュの整理", systemImage: "internaldrive") }
                NavigationLink { BackupsView() } label: { Label("バックアップと復元", systemImage: "externaldrive.badge.timemachine") }
            }
            Section {
                NavigationLink { RuntimeDetailsView() } label: { Label("実行環境とセットアップ", systemImage: "iphone") }
                NavigationLink { PathEnumerationView(initialPath: "/var/mobile/Containers/Data/Application") } label: { Label("コンテナを探す", systemImage: "magnifyingglass") }
                NavigationLink { AccessHelpView() } label: { Label("アクセス範囲と注意事項", systemImage: "info.circle") }
                Button("残ったアクセス状態を破棄", role: .destructive) { model.releaseAll() }
            } header: { Text("アクセス") }
            Section {
                NavigationLink { LogView() } label: {
                    Label("操作ログ", systemImage: "list.bullet.rectangle")
                }
            }
            Section {
                NavigationLink { RespringSettingsView() } label: {
                    Label("リスプリング", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
            } header: { Text("端末操作") }
        }
        .navigationTitle("設定")
        .disabled(model.busy)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return build
        case (nil, nil): return "—"
        }
    }
}

struct RespringSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRespring = false
    @State private var showRespring = false

    var body: some View {
        Form {
            Section {
                Text("実行前に作業を保存してください。")
                Text("フリーズ・アプリの終了・未保存データの損失が起きる場合があります。")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("試行の上限", value: L("8秒（固定）"))
                Button("リスプリング", role: .destructive) { confirmRespring = true }
                    .disabled(model.busy)
            }
        }
        .navigationTitle("リスプリング").navigationBarTitleDisplayMode(.inline)
        .alert("リスプリングしますか？", isPresented: $confirmRespring) {
            Button("リスクを理解して実行", role: .destructive) {
                model.log(L("ユーザー確認後、リスプリングを実行（上限8秒）。"))
                showRespring = true
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("画面が消える・ロック画面に戻る・端末が応答しなくなる可能性があります。未保存のデータは失われる場合があります。確実なリスプリングではありません。") }
        .fullScreenCover(isPresented: $showRespring) { RespringAttemptView().environment(model) }
    }
}

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("TaiKueriRunner", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("作者", value: "taisan11")
                Link("GitHub", destination: URL(string: "https://github.com/taisan11/TaiKueriRunner")!)
                Text("自分の端末・許可されたデータ向けの開発・研究用ユーティリティです。")
                    .foregroundStyle(.secondary)
            }
            Section("クレジット") {
                Link("worse_query — forcequitOS", destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
                Link("WQFiles — kolbicz", destination: URL(string: "https://github.com/kolbicz/WQFiles")!)
                Link("MGKeys — PoomSmart (MIT)", destination: URL(string: "https://github.com/PoomSmart/MGKeys")!)
                NavigationLink("MGKeysライセンス") {
                    ScrollView {
                        Text(Bundle.main.url(forResource: "MGKeys-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L("ライセンスはソースのVendor/MGKeys/LICENSEを参照してください。"))
                            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding()
                    }.navigationTitle("MGKeys · MIT")
                }
                Link("neospring — rooootdev", destination: URL(string: "https://github.com/rooootdev/neospring")!)
                Text("worse_query / pathleak: Taj C (forcequit), GPL-3.0-or-later\nLaunchServices DB解析・探索方式: WQFiles / kolbicz, GPL-3.0-or-later\nRespring方式: neon / skadz / rooootdev\n詳細はリポジトリのTHIRD_PARTY.mdを参照。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("このアプリについて").navigationBarTitleDisplayMode(.inline)
    }
}

struct LogView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            if model.logs.isEmpty {
                ContentUnavailableView("ログはありません", systemImage: "list.bullet.rectangle")
            } else {
                Section {
                    ForEach(model.logs) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.date, style: .time).foregroundStyle(.secondary)
                            Text(entry.message).foregroundStyle(entry.isError ? .red : .primary)
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } footer: {
                    Text("共有前にパスなどの個人情報を確認してください。")
                }
            }
        }
        .navigationTitle("操作ログ").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: model.logText) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("ログを共有")
                .disabled(model.logs.isEmpty)
            Menu {
                Button("ログをクリア", systemImage: "trash", role: .destructive) { model.clearLogs() }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("ログの操作")
                .disabled(model.logs.isEmpty)
        }
    }
}
