import SwiftUI
import UIKit

/// Entry point for the editing and viewer features.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12)]

    private var supported: Bool {
        RuntimeSupport.isReportedSupported(ProcessInfo.processInfo.operatingSystemVersion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                features
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("ホーム")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("TaiKueriRunner", systemImage: "wrench.and.screwdriver.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.teal)
            Text("端末のカスタマイズツール")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("対応バージョン", value: RuntimeSupport.allowedVersionRange)
                LabeledContent("現在のバージョン") {
                    HStack(spacing: 6) {
                        Text(UIDevice.current.systemVersion)
                        Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(supported ? Color.teal : Color.red)
                    }
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var features: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(AppFeature.topLayer) { feature in
                NavigationLink {
                    destination(for: feature)
                } label: {
                    FeatureCard(feature: feature)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func destination(for feature: AppFeature) -> some View {
        switch feature {
        case .wallpaper: WallpaperView()
        case .keypad: KeypadView()
        case .lineViewer: LINEHubView()
        case .mobileGestalt: MobileGestaltView()
        case .applications: ApplicationsView()
        case .appGroups: AppGroupsView()
        case .fileViewer:
            FileBrowserView(path: Binding(get: { model.browserPath }, set: { model.browserPath = $0 }))
        }
    }
}

private struct FeatureCard: View {
    let feature: AppFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: feature.systemImage)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 44, height: 44)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(feature.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(height: 42, alignment: .topLeading)
            Text(feature.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
