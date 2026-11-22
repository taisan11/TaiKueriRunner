import SwiftUI

/// The app is organised in three layers.
///
/// - top: user-facing editing and viewers (wallpaper, keypad, LINE, MobileGestalt)
/// - middle: discovering and displaying applications and App Groups
/// - bottom: raw file browsing and file previews
///
/// Higher layers may use the lower layers. The lower layers do not own the
/// top-level screens; they only receive a path or hand a file up when needed.
enum AppLayer: Int, CaseIterable, Identifiable, Sendable {
    case top
    case middle
    case bottom

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .top: L("最上位層")
        case .middle: L("中位層")
        case .bottom: L("下位層")
        }
    }

    var summary: String {
        switch self {
        case .top: L("編集・ビューア")
        case .middle: L("アプリ・App Groups")
        case .bottom: L("ファイル")
        }
    }

    var detail: String {
        switch self {
        case .top: L("壁紙、キーパッド、LINE、MobileGestaltを編集・閲覧します。")
        case .middle: L("端末のアプリと共有フォルダを読み込み、対象を選びます。")
        case .bottom: L("パスを直接たどり、ファイルの中身を確認します。")
        }
    }

    var systemImage: String {
        switch self {
        case .top: "square.3.layers.3d.top.filled"
        case .middle: "square.3.layers.3d"
        case .bottom: "square.3.layers.3d.bottom.filled"
        }
    }

    /// Where the layer is normally entered from.
    var entryPoint: String {
        switch self {
        case .top: L("このホーム")
        case .middle: L("「アプリ」タブ")
        case .bottom: L("「ファイル」タブ")
        }
    }
}

/// All feature screens, grouped by the layer they belong to.
enum AppFeature: String, CaseIterable, Identifiable, Sendable {
    case wallpaper
    case keypad
    case lineViewer
    case mobileGestalt
    case applications
    case appGroups
    case fileViewer

    var id: String { rawValue }

    var layer: AppLayer {
        switch self {
        case .wallpaper, .keypad, .lineViewer, .mobileGestalt: .top
        case .applications, .appGroups: .middle
        case .fileViewer: .bottom
        }
    }

    var title: String {
        switch self {
        case .wallpaper: L("壁紙編集")
        case .keypad: L("キーパッド編集")
        case .lineViewer: L("LINEビューア")
        case .mobileGestalt: L("MobileGestalt編集")
        case .applications: L("アプリ")
        case .appGroups: "App Groups"
        case .fileViewer: L("ファイルビューア")
        }
    }

    var summary: String {
        switch self {
        case .wallpaper: L("端末の壁紙を確認し、tendie・Batterから追加・削除します。")
        case .keypad: L("電話アプリのキー画像をテーマや個別画像で変更します。")
        case .lineViewer: L("端末の共有フォルダからLINEのトークを直接読みます。")
        case .mobileGestalt: L("端末の対応情報キャッシュを確認し、機能別に編集します。")
        case .applications: L("LaunchServices DBからアプリと拡張機能を一覧表示します。")
        case .appGroups: L("共有フォルダと、共有を宣言したアプリを調べます。")
        case .fileViewer: L("任意のパスをたどり、テキスト・Plist・SQLite等を表示します。")
        }
    }

    var systemImage: String {
        switch self {
        case .wallpaper: "photo.stack"
        case .keypad: "phone"
        case .lineViewer: "bubble.left.and.bubble.right"
        case .mobileGestalt: "slider.horizontal.3"
        case .applications: "square.grid.2x2"
        case .appGroups: "folder.badge.person.crop"
        case .fileViewer: "folder"
        }
    }

    static var topLayer: [AppFeature] { allCases.filter { $0.layer == .top } }
    static var middleLayer: [AppFeature] { allCases.filter { $0.layer == .middle } }
    static var bottomLayer: [AppFeature] { allCases.filter { $0.layer == .bottom } }
}

/// Tab identifiers. The order follows the layer order: home first, then the
/// middle layer, then the bottom layer, and settings last.
enum AppTab: Int, CaseIterable, Identifiable, Sendable {
    case home
    case applications
    case files
    case settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: L("ホーム")
        case .applications: L("アプリ")
        case .files: L("ファイル")
        case .settings: L("設定")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .applications: "square.grid.2x2"
        case .files: "folder"
        case .settings: "gearshape"
        }
    }
}
