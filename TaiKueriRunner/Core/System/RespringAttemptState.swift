import Foundation

struct RespringAttemptState: Sendable {
    enum Phase: Equatable, Sendable { case preparing, running, stopped }
    enum Event: Sendable { case started, pageLoaded, stopped(StopReason) }
    enum StopReason: Equatable, Sendable {
        case user, timeout, background, disappeared, pageEnded, webContentTerminated
        case failed(String)

        var message: String {
            switch self {
            case .user: L("ユーザー操作で停止しました。")
            case .timeout: L("設定した試行上限に達したため停止しました。")
            case .background: L("バックグラウンドへ移行したため停止しました。")
            case .disappeared: L("試行画面を閉じたため停止しました。")
            case .pageEnded: L("WebKitの試行ページが終了しました。")
            case .webContentTerminated: L("WebKitのコンテンツプロセスが終了しました。リスプリングの成功ではありません。")
            case .failed(let detail): L("試行できませんでした: \(String(describing: detail))")
            }
        }

        var isError: Bool {
            switch self {
            case .failed, .webContentTerminated: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .preparing
    private(set) var stopReason: StopReason?
    var isActive: Bool { phase != .stopped }

    // Late WebKit callbacks must never restart a stopped attempt or overwrite its reason.
    @discardableResult
    mutating func receive(_ event: Event) -> Bool {
        guard isActive else { return false }
        switch event {
        case .started:
            guard phase == .preparing else { return false }
            phase = .running
        case .pageLoaded:
            // A busy child script may delay didFinish. It is diagnostic only,
            // never the trigger for a watchdog or proof that pressure ran.
            guard phase == .running else { return false }
        case .stopped(let reason):
            phase = .stopped
            stopReason = reason
        }
        return true
    }
}
