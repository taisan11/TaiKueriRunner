import SwiftUI
import WebKit

struct RespringAttemptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = RespringAttemptState()
    @State private var showPressure = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if state.isActive && showPressure {
                RenderingPressureView(onEvent: receive)
                    .brightness(-1).ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack(spacing: 20) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").font(.largeTitle).foregroundStyle(.orange)
                Text(title).font(.title2.bold())
                Text(state.stopReason?.message ?? L("8秒で停止します。OSが応答しない場合は停止できないことがあります。"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !state.isActive {
                    Text("リスプリングの成否は自動判定できません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(state.isActive ? L("負荷を停止") : L("閉じる")) {
                    if state.isActive { receive(.stopped(.user)) } else { dismiss() }
                }.buttonStyle(.borderedProminent)
            }.padding(28).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20)).padding(20)
        }
        .interactiveDismissDisabled(state.isActive)
        .preferredColorScheme(.dark)
        .task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if state.isActive {
                showPressure = true
                receive(.started)
            }
        }
        .task(id: state.phase) {
            let phase = state.phase
            guard state.isActive else { return }
            let seconds = phase == .preparing ? RespringDocument.preparationTimeoutSeconds : RespringDocument.attemptSeconds
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard state.phase == phase else { return }
            receive(.stopped(phase == .preparing ? .failed(L("WebKitの準備がタイムアウトしました。")) : .timeout))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { receive(.stopped(.background)) }
        }
        .onDisappear { receive(.stopped(.disappeared)) }
    }

    private var title: String {
        switch state.phase {
        case .preparing: L("WebKitを準備中")
        case .running: L("リスプリングを試行中")
        case .stopped: L("試行を停止しました")
        }
    }

    private func receive(_ event: RespringAttemptState.Event) {
        guard state.receive(event) else { return }
        switch event {
        case .started: model.log(L("リスプリングを開始（上限8秒）。"))
        case .pageLoaded: model.log(L("リスプリング用ページを読み込みました。"))
        case .stopped(let reason): model.log(L("WebKit: \(String(describing: reason.message)) 成否は未確認。"), error: reason.isError)
        }
    }
}

private struct RenderingPressureView: UIViewRepresentable {
    var onEvent: @MainActor (RespringAttemptState.Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Match neospring's standard WKWebView data store. This local page has
        // no external resources and never reads or shares user files.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isUserInteractionEnabled = false
        view.loadHTMLString(RespringDocument.html(), baseURL: nil)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {} // Do not reload on SwiftUI updates.

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.tornDown = true
        uiView.navigationDelegate = nil
        // stopLoading alone does not stop JavaScript. Remove the iframe and navigate away,
        // without waiting for a potentially unresponsive content process to acknowledge.
        uiView.evaluateJavaScript("window.stopPressure && window.stopPressure();", completionHandler: nil)
        uiView.stopLoading()
        uiView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        uiView.removeFromSuperview()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onEvent: @MainActor (RespringAttemptState.Event) -> Void
        var tornDown = false
        private var loaded = false

        init(onEvent: @escaping @MainActor (RespringAttemptState.Event) -> Void) {
            self.onEvent = onEvent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !tornDown, !loaded else { return }
            loaded = true
            onEvent(.pageLoaded)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !tornDown { onEvent(.stopped(.webContentTerminated)) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail(error)
        }

        private func fail(_ error: any Error) {
            if !tornDown { onEvent(.stopped(.failed(error.localizedDescription))) }
        }
    }
}
