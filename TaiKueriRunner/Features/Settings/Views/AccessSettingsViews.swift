import SwiftUI
import UIKit
import Darwin

struct RuntimeDetailsView: View {
    @Environment(AppModel.self) private var model
    private var supported: Bool { RuntimeSupport.isReportedSupported(ProcessInfo.processInfo.operatingSystemVersion) }

    private var version: String { UIDevice.current.systemName + " " + UIDevice.current.systemVersion }
    private var build: String { ProcessInfo.processInfo.operatingSystemVersionString }
    private var deviceModel: String { Self.machineIdentifier() }
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

    var body: some View {
        Form {
            Section {
                LabeledContent("OS", value: version)
                LabeledContent("ビルド", value: build)
                LabeledContent("機種", value: deviceModel)
                LabeledContent("実行許可範囲", value: RuntimeSupport.allowedVersionRange)
                LabeledContent("互換性") {
                    Label(supported ? L("範囲内・動作未保証") : L("対応範囲外"),
                          systemImage: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(supported ? Color.teal : Color.red)
                }
            } header: { Text("実行環境") } footer: {
                Text("対応範囲内でも動作を保証するものではありません。")
            }
            Section {
                LabeledContent("アプリのバージョン", value: appVersion)
                LabeledContent("プロセッサ", value: L("\(String(describing: ProcessInfo.processInfo.processorCount))コア（有効 \(String(describing: ProcessInfo.processInfo.activeProcessorCount))）"))
                LabeledContent("物理メモリ", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent("実行形態", value: isSimulator ? L("シミュレータ") : L("実機"))
            } header: { Text("アプリ / 端末") }
            Section {
                if let group = RuntimeSupport.appGroup {
                    Label("コンテナにアクセス可能", systemImage: "checkmark.circle").foregroundStyle(.teal)
                    Text(group.identifier).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text(group.containerURL.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("App Groupを開く", systemImage: "folder") { model.browse(group.containerURL.path) }
                } else {
                    Label("App Groupを利用できません", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("AltStore・SideStore・SideloadlyでApple IDを使って再インストールしてください。App Groupsの宣言を削除しない設定にしてください。")
                }
                LabeledContent("署名のApp Groups", value: RuntimeSupport.entitledGroupIDs.isEmpty ? L("なし / 取得不可") : RuntimeSupport.entitledGroupIDs.joined(separator: ", "))
            } header: { Text("Apple ID / App Group") } footer: {
                Text("他のアプリと共有しない専用Groupを使用してください。")
            }
            Section {
                DisclosureGroup("詳細情報") {
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                    LabeledContent("プロセス", value: ProcessInfo.processInfo.processName)
                    LabeledContent("プロセッサ数", value: "\(ProcessInfo.processInfo.processorCount)")
                    LabeledContent("システム起動時間", value: L("\(String(describing: ProcessInfo.processInfo.systemUptime.formatted(.number.precision(.fractionLength(0)))))秒"))
                    LabeledContent("低電力モード", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? L("オン") : L("オフ"))
                }
            }
        }
        .navigationTitle("実行環境とセットアップ").navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

struct AccessHelpView: View {
    var body: some View {
        List {
            Section("実行前に") {
                Text("自分の端末・許可されたデータにのみ使用し、事前にバックアップしてください。root権限の取得や脱獄ではなく、システム全体にはアクセスできません。")
            }
            Section("アクセス範囲の目安") {
                ForEach(PathPreset.availableContainers(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)) { preset in
                    PathPresetRow(preset: preset)
                }
            }
        }
        .navigationTitle("アクセス範囲と注意事項").navigationBarTitleDisplayMode(.inline)
    }
}
